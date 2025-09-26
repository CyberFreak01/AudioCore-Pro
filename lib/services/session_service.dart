import 'dart:io';
import 'package:dio/dio.dart';

class SessionService {
  final Dio _dio;
  final String baseUrl;

  SessionService(this.baseUrl) : _dio = Dio() {
    _dio.options.baseUrl = baseUrl;
    _dio.options.connectTimeout = const Duration(seconds: 5);
    _dio.options.receiveTimeout = const Duration(seconds: 10);
  }

  /// Create a new recording session
  Future<String?> createSession() async {
    try {
      final response = await _dio.post('/upload-session');
      if (response.data['success'] == true) {
        return response.data['sessionId'] as String;
      }
      return null;
    } on DioException catch (e) {
      print('Error creating session: ${e.message}');
      return null;
    }
  }

  /// Get presigned URL for uploading audio chunk
  Future<String?> getPresignedUrl(String sessionId, int chunkNumber) async {
    try {
      final response = await _dio.post('/get-presigned-url', data: {
        'sessionId': sessionId,
        'chunkNumber': chunkNumber,
      });
      if (response.data['success'] == true) {
        return response.data['presignedUrl'] as String;
      }
      return null;
    } on DioException catch (e) {
      print('Error getting presigned URL: ${e.message}');
      return null;
    }
  }

  /// Upload audio chunk to server
  Future<bool> uploadChunk(String sessionId, int chunkNumber, File audioFile) async {
    try {
      final formData = FormData.fromMap({
        'audio': await MultipartFile.fromFile(
          audioFile.path,
          filename: 'chunk_$chunkNumber.wav',
        ),
      });

      final response = await _dio.post(
        '/upload-chunk/$sessionId/$chunkNumber',
        data: formData,
      );
      
      return response.data['success'] == true;
    } on DioException catch (e) {
      print('Error uploading chunk: ${e.message}');
      return false;
    }
  }

  /// Notify server that chunk was uploaded
  Future<bool> notifyChunkUploaded(String sessionId, int chunkNumber, {String? checksum}) async {
    try {
      final response = await _dio.post('/notify-chunk-uploaded', data: {
        'sessionId': sessionId,
        'chunkNumber': chunkNumber,
        if (checksum != null) 'checksum': checksum,
      });
      
      return response.data['success'] == true;
    } on DioException catch (e) {
      print('Error notifying chunk upload: ${e.message}');
      return false;
    }
  }

  /// Get all sessions
  Future<List<Map<String, dynamic>>> getAllSessions() async {
    try {
      final response = await _dio.get('/all-session');
      if (response.data['success'] == true) {
        return List<Map<String, dynamic>>.from(response.data['sessions']);
      }
      return [];
    } on DioException catch (e) {
      print('Error getting sessions: ${e.message}');
      return [];
    }
  }
}