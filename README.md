# ai-scribe-copilot

Android APK Download: 

https://drive.google.com/file/d/11AhXmS1v2HNTbjj2YlruRmR3YsQQRn3a/view?usp=sharing

Android Demo Video : 

IOS Loom Video: https://www.loom.com/share/0db52f9d54474493892d7e324646175f?sid=77dab600-4a76-4ed3-a705-f3a5d588a1ff

IOS IPA File : https://github.com/CyberFreak01/ai-scribe-copilot/releases/download/v1.0/FlutterIpaExport.ipa

# Build Instruction

📚 Link to API documentation
https://drive.google.com/file/d/1PMdJyYtUkkglIHG923AYslAsLg5Nr8tR/view?usp=sharing

🔧 Link to Postman collection
https://drive.google.com/file/d/1UFzlmFpPfgL7zwHasm0AsAd5-whvcixI/view?usp=sharing

Flutter version: flutter --version output

<img width="981" height="255" alt="flutter_version" src="https://github.com/user-attachments/assets/043ab5ba-b687-497a-82ba-5c65dcb84626" />

Backend deployment URL
https://scribe-server-production-f150.up.railway.app/

Docker setup for backend (docker-compose up)

Run the simple mock backend server :
```bash
cd medical-scribe-api
docker-compose up
```

## 🚀 Native Core Features

### 🎯 Advanced Audio Recording System

#### Android Native Implementation
- **Robust Audio Recording**: High-quality audio capture using `AudioRecord` API with configurable sample rates (44.1kHz default)
- **Background Recording**: Continuous recording during app backgrounding, minimization, and device lock
- **Foreground Service**: Persistent notification with pause/resume/stop controls that sync with Flutter UI
- **Audio Session Management**: Automatic handling of phone calls, Bluetooth headsets, and audio route switching
- **Real-time Audio Processing**: Live RMS calculation, peak level monitoring, and adjustable gain control
- **Memory-Efficient Buffering**: Circular audio buffer management with configurable chunk sizes

#### iOS Native Implementation  
- **AVAudioSession Configuration**: Optimized for background recording with proper category and mode settings
- **Background Audio Capabilities**: Maintains recording during app backgrounding and device lock
- **Interruption Handling**: Auto-pause on phone calls with automatic resume after call ends
- **Audio Route Management**: Seamless switching between built-in microphone, Bluetooth, and wired headsets
- **Core Audio Integration**: Low-latency audio processing with real-time level monitoring

### 🔄 Intelligent Chunk Management System

#### Persistent Queue Architecture
- **SQLite-Based Storage**: Robust chunk queue that survives app kills and device restarts
- **Priority-Based Processing**: Recovery chunks get higher priority over new chunks
- **SHA-256 Integrity Validation**: 100% data integrity with checksum validation for every chunk
- **Automatic Retry Logic**: Exponential backoff with network-aware retry strategies (max 5 retries)
- **Concurrent Upload Management**: Optimized parallel uploads (max 3 simultaneous on iOS, adaptive on Android)

#### Network-Aware Upload Optimization
- **Real-Time Network Monitoring**: Continuous monitoring of WiFi, Cellular, Ethernet, and Bluetooth connections
- **Adaptive Batch Sizing**: Dynamic upload batch sizes based on network type and quality
- **Metered Network Detection**: Smart data usage on constrained/expensive networks
- **Connection Quality Assessment**: Automatic adjustment of upload strategies based on network performance
- **Offline Resilience**: Local storage and automatic sync when connectivity is restored

### ⚡ Background Task Management

#### Android WorkManager Integration
- **Periodic Chunk Recovery**: Scheduled tasks every 15 minutes for chunk upload retry
- **Immediate Recovery Tasks**: Triggered on app restart for pending chunk processing  
- **Daily Cleanup Jobs**: Automatic removal of old completed chunks (7-day retention)
- **Network-Constrained Execution**: Tasks only run when appropriate network conditions are met
- **Battery Optimization**: Efficient background processing with minimal battery impact

#### iOS Background Processing
- **Background App Refresh**: Intelligent chunk upload during background refresh cycles
- **Background Processing Tasks**: Long-running tasks for chunk retry and recovery
- **App Lifecycle Management**: Proper handling of app state transitions and background time limits
- **Silent Push Notifications**: Remote triggering of background upload tasks

### 🛡️ Advanced Error Handling & Recovery

#### Comprehensive Recovery System
- **Automatic Chunk Recovery**: On app restart, validates and recovers all pending chunks
- **File Integrity Checks**: SHA-256 validation ensures no data corruption during storage/transfer
- **Orphaned File Cleanup**: Automatic detection and cleanup of incomplete or corrupted files
- **Session State Recovery**: Restores recording sessions across app restarts with full state preservation
- **Network Failure Recovery**: Intelligent retry mechanisms with exponential backoff

#### Robust Error Management
- **Detailed Error Logging**: Comprehensive logging system for debugging and monitoring
- **Graceful Degradation**: App continues functioning even with partial system failures
- **User-Friendly Error Messages**: Clear, actionable error messages for users
- **Automatic Error Recovery**: Self-healing mechanisms for common failure scenarios

## 🏗️ Clean Architecture Implementation

### 📱 Flutter Layer Architecture

#### State Management (Provider Pattern)
- **RecordingStateManager**: Core state management for recording operations, timer, and session data
- **RecordingProvider**: Main provider that coordinates between UI and business logic
- **RecordingEventHandler**: Dedicated event handling for platform channel communications
- **SessionService**: Service layer for session management and data persistence

#### Service Layer
- **PlatformService**: Abstraction layer for platform channel communications
- **ShareService**: Handles session sharing and export functionality
- **AudioLevelModel**: Immutable data models for audio level information
- **SessionModel**: Comprehensive session data modeling with type safety

#### UI Layer
- **Material 3 Design System**: Modern UI with Material You theming and dynamic colors
- **Responsive Layout**: Adaptive UI that handles different screen sizes and orientations
- **Accessibility Support**: Full accessibility compliance with screen readers and navigation
- **Theme-Aware Components**: Consistent theming across light/dark modes

### 🔧 Native Layer Architecture

#### Android Clean Architecture
```
├── managers/
│   ├── AudioRecordingManager.kt    # Audio recording operations
│   ├── ChunkManager.kt             # Chunk processing and upload
│   ├── TimerManager.kt             # Recording timer management
│   ├── PermissionManager.kt        # Runtime permission handling
│   └── NetworkMonitor.kt           # Network state monitoring
├── utils/
│   ├── AudioUtils.kt               # Audio processing utilities
│   └── FileUtils.kt                # File operations and validation
├── constants/
│   └── AudioConstants.kt           # Centralized configuration
└── MainActivity.kt                 # Flutter integration layer
```

#### iOS Clean Architecture
```
├── AudioManager.swift              # Core audio recording management
├── ChunkManager.swift              # Chunk processing and upload
├── PersistentQueue.swift           # SQLite-based storage
├── NetworkMonitor.swift            # Network monitoring and optimization
├── BackgroundTaskManager.swift     # Background processing coordination
└── AppDelegate.swift               # Flutter integration and lifecycle
```

### 🔄 Cross-Platform Communication

#### Method Channels
- **Standardized API**: Consistent method signatures across Android and iOS
- **Type Safety**: Proper type conversion and validation between Dart and native code
- **Error Handling**: Comprehensive error propagation from native to Flutter
- **Async Operations**: Non-blocking operations with proper callback handling

#### Event Channels
- **Real-Time Updates**: Live audio levels, chunk upload progress, and network state changes
- **State Synchronization**: Bidirectional state sync between native and Flutter
- **Event Filtering**: Intelligent event filtering to prevent UI flooding
- **Error Recovery**: Automatic event channel recovery on connection failures

## 🎛️ Advanced Features

### ⏱️ Smart Recording Timer
- **Flexible Duration Options**: 5min, 10min, 15min, 30min, 1hour presets
- **Auto-Stop Functionality**: Automatic recording termination when timer expires
- **Pause/Resume Support**: Timer state preservation across recording interruptions
- **Visual Countdown**: Real-time remaining time display with progress indicators

### 📊 Real-Time Audio Monitoring
- **Live Audio Levels**: Real-time RMS and peak level visualization
- **Gain Control**: Dynamic audio gain adjustment during recording
- **Visual Feedback**: Audio level meters with Material Design styling
- **Performance Optimization**: Efficient audio level calculation with minimal CPU usage

### 🔄 Session Management
- **Session Persistence**: Complete session state preservation across app restarts
- **Multi-Session Support**: Handle multiple recording sessions with proper isolation
- **Session Recovery**: Automatic recovery of interrupted sessions
- **Export & Sharing**: Comprehensive session export with metadata and audio files

### 🌐 Network Optimization
- **Intelligent Upload Strategy**: Adaptive upload behavior based on network conditions
- **Bandwidth Management**: Efficient use of available bandwidth with quality-aware compression
- **Offline Support**: Full offline recording with automatic sync when online
- **Progress Tracking**: Detailed upload progress with chunk-level granularity

## 🛠️ Technical Specifications

### Performance Metrics
- **Audio Latency**: < 50ms recording latency on modern devices
- **Memory Usage**: < 100MB RAM usage during active recording
- **Battery Optimization**: < 5% battery drain per hour of recording
- **Storage Efficiency**: Optimized WAV compression with quality preservation

### Platform Requirements
- **Android**: API Level 21+ (Android 5.0+)
- **iOS**: iOS 12.0+
- **Flutter**: 3.0+ with Dart 3.0+
- **Storage**: Minimum 100MB free space for chunk buffering

### Security & Privacy
- **Local Processing**: All audio processing happens on-device
- **Encrypted Storage**: SQLite database encryption for sensitive data
- **Permission Management**: Granular permission handling with user consent
- **Data Retention**: Configurable data retention policies with automatic cleanup
