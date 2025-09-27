import Foundation
import SQLite3

class PersistentQueue {
    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "PersistentQueue.database", qos: .utility)
    
    init() {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        dbPath = "\(documentsPath)/audio_chunks.db"
        openDatabase()
        createTables()
    }
    
    deinit {
        closeDatabase()
    }
    
    // MARK: - Database Operations
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("PersistentQueue: Unable to open database at \(dbPath)")
            db = nil
        }
    }
    
    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }
    
    private func createTables() {
        let createTableSQL = """
            CREATE TABLE IF NOT EXISTS audio_chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                chunk_number INTEGER NOT NULL,
                file_path TEXT NOT NULL,
                checksum TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                sample_rate REAL NOT NULL,
                duration REAL NOT NULL,
                upload_status TEXT NOT NULL,
                retry_count INTEGER NOT NULL DEFAULT 0,
                last_retry_time REAL,
                created_at REAL NOT NULL DEFAULT (julianday('now')),
                UNIQUE(session_id, chunk_number)
            );
        """
        
        let createIndexSQL = """
            CREATE INDEX IF NOT EXISTS idx_session_chunk ON audio_chunks(session_id, chunk_number);
            CREATE INDEX IF NOT EXISTS idx_upload_status ON audio_chunks(upload_status);
            CREATE INDEX IF NOT EXISTS idx_timestamp ON audio_chunks(timestamp);
        """
        
        queue.sync {
            if sqlite3_exec(db, createTableSQL, nil, nil, nil) != SQLITE_OK {
                print("PersistentQueue: Error creating table")
            }
            
            if sqlite3_exec(db, createIndexSQL, nil, nil, nil) != SQLITE_OK {
                print("PersistentQueue: Error creating indexes")
            }
        }
    }
    
    // MARK: - Public Interface
    func saveChunk(_ chunk: AudioChunk) {
        let insertSQL = """
            INSERT OR REPLACE INTO audio_chunks 
            (session_id, chunk_number, file_path, checksum, file_size, timestamp, 
             sample_rate, duration, upload_status, retry_count, last_retry_time)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        queue.async {
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, insertSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, chunk.sessionId, -1, nil)
                sqlite3_bind_int(statement, 2, Int32(chunk.chunkNumber))
                sqlite3_bind_text(statement, 3, chunk.filePath, -1, nil)
                sqlite3_bind_text(statement, 4, chunk.checksum, -1, nil)
                sqlite3_bind_int64(statement, 5, chunk.fileSize)
                sqlite3_bind_double(statement, 6, chunk.timestamp.timeIntervalSince1970)
                sqlite3_bind_double(statement, 7, chunk.sampleRate)
                sqlite3_bind_double(statement, 8, chunk.duration)
                sqlite3_bind_text(statement, 9, chunk.uploadStatus.rawValue, -1, nil)
                sqlite3_bind_int(statement, 10, Int32(chunk.retryCount))
                
                if let lastRetryTime = chunk.lastRetryTime {
                    sqlite3_bind_double(statement, 11, lastRetryTime.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 11)
                }
                
                if sqlite3_step(statement) != SQLITE_DONE {
                    print("PersistentQueue: Error saving chunk")
                }
            } else {
                print("PersistentQueue: Error preparing insert statement")
            }
            
            sqlite3_finalize(statement)
        }
    }
    
    func loadAllChunks() -> [AudioChunk] {
        let selectSQL = """
            SELECT session_id, chunk_number, file_path, checksum, file_size, 
                   timestamp, sample_rate, duration, upload_status, retry_count, last_retry_time
            FROM audio_chunks 
            WHERE upload_status != 'uploaded'
            ORDER BY timestamp ASC;
        """
        
        var chunks: [AudioChunk] = []
        
        queue.sync {
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, selectSQL, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    let sessionId = String(cString: sqlite3_column_text(statement, 0))
                    let chunkNumber = Int(sqlite3_column_int(statement, 1))
                    let filePath = String(cString: sqlite3_column_text(statement, 2))
                    let checksum = String(cString: sqlite3_column_text(statement, 3))
                    let fileSize = sqlite3_column_int64(statement, 4)
                    let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                    let sampleRate = sqlite3_column_double(statement, 6)
                    let duration = sqlite3_column_double(statement, 7)
                    let uploadStatusString = String(cString: sqlite3_column_text(statement, 8))
                    let retryCount = Int(sqlite3_column_int(statement, 9))
                    
                    var lastRetryTime: Date?
                    if sqlite3_column_type(statement, 10) != SQLITE_NULL {
                        lastRetryTime = Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
                    }
                    
                    // Create chunk with loaded data
                    var chunk = AudioChunk(sessionId: sessionId, chunkNumber: chunkNumber, 
                                         filePath: filePath, sampleRate: sampleRate, duration: duration)
                    
                    // Override computed values with stored ones
                    chunk = AudioChunk(
                        sessionId: sessionId,
                        chunkNumber: chunkNumber,
                        filePath: filePath,
                        checksum: checksum,
                        fileSize: fileSize,
                        timestamp: timestamp,
                        sampleRate: sampleRate,
                        duration: duration,
                        uploadStatus: ChunkUploadStatus(rawValue: uploadStatusString) ?? .pending,
                        retryCount: retryCount,
                        lastRetryTime: lastRetryTime
                    )
                    
                    // Only add if file still exists
                    if FileManager.default.fileExists(atPath: filePath) {
                        chunks.append(chunk)
                    } else {
                        // Clean up orphaned database entry
                        self.deleteChunk(sessionId: sessionId, chunkNumber: chunkNumber)
                    }
                }
            }
            
            sqlite3_finalize(statement)
        }
        
        return chunks
    }
    
    func updateChunkStatus(sessionId: String, chunkNumber: Int, status: ChunkUploadStatus) {
        let updateSQL = """
            UPDATE audio_chunks 
            SET upload_status = ?, last_retry_time = ?
            WHERE session_id = ? AND chunk_number = ?;
        """
        
        queue.async {
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, updateSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, status.rawValue, -1, nil)
                
                if status == .failed || status == .retrying {
                    sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 2)
                }
                
                sqlite3_bind_text(statement, 3, sessionId, -1, nil)
                sqlite3_bind_int(statement, 4, Int32(chunkNumber))
                
                if sqlite3_step(statement) != SQLITE_DONE {
                    print("PersistentQueue: Error updating chunk status")
                }
            }
            
            sqlite3_finalize(statement)
        }
    }
    
    func deleteChunk(sessionId: String, chunkNumber: Int) {
        let deleteSQL = "DELETE FROM audio_chunks WHERE session_id = ? AND chunk_number = ?;"
        
        queue.async {
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, sessionId, -1, nil)
                sqlite3_bind_int(statement, 2, Int32(chunkNumber))
                
                sqlite3_step(statement)
            }
            
            sqlite3_finalize(statement)
        }
    }
    
    func deleteSession(sessionId: String) {
        let deleteSQL = "DELETE FROM audio_chunks WHERE session_id = ?;"
        
        queue.async {
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, sessionId, -1, nil)
                sqlite3_step(statement)
            }
            
            sqlite3_finalize(statement)
        }
    }
    
    func cleanupOldChunks(olderThanDays days: Int = 7) {
        let cutoffTime = Date().addingTimeInterval(-TimeInterval(days * 24 * 60 * 60))
        let deleteSQL = """
            DELETE FROM audio_chunks 
            WHERE upload_status = 'uploaded' AND timestamp < ?;
        """
        
        queue.async {
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_double(statement, 1, cutoffTime.timeIntervalSince1970)
                sqlite3_step(statement)
            }
            
            sqlite3_finalize(statement)
        }
    }
    
    func getQueueStats() -> [String: Any] {
        let statsSQL = """
            SELECT 
                upload_status,
                COUNT(*) as count,
                SUM(file_size) as total_size
            FROM audio_chunks 
            GROUP BY upload_status;
        """
        
        var stats: [String: Any] = [:]
        
        queue.sync {
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, statsSQL, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    let status = String(cString: sqlite3_column_text(statement, 0))
                    let count = Int(sqlite3_column_int(statement, 1))
                    let totalSize = sqlite3_column_int64(statement, 2)
                    
                    stats[status] = [
                        "count": count,
                        "totalSize": totalSize
                    ]
                }
            }
            
            sqlite3_finalize(statement)
        }
        
        return stats
    }
}

// MARK: - AudioChunk Extension for Database
extension AudioChunk {
    init(sessionId: String, chunkNumber: Int, filePath: String, checksum: String, 
         fileSize: Int64, timestamp: Date, sampleRate: Double, duration: Double,
         uploadStatus: ChunkUploadStatus, retryCount: Int, lastRetryTime: Date?) {
        self.sessionId = sessionId
        self.chunkNumber = chunkNumber
        self.filePath = filePath
        self.checksum = checksum
        self.fileSize = fileSize
        self.timestamp = timestamp
        self.sampleRate = sampleRate
        self.duration = duration
        self.uploadStatus = uploadStatus
        self.retryCount = retryCount
        self.lastRetryTime = lastRetryTime
    }
}
