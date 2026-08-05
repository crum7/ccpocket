import 'dart:typed_data';

const int maxAttachmentCount = 5;
const int maxFileAttachmentBytes = 10 * 1024 * 1024;

class FileAttachment {
  final String name;
  final String mimeType;
  final Uint8List bytes;

  const FileAttachment({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  bool get isSupportedImage =>
      mimeType == 'image/png' ||
      mimeType == 'image/jpeg' ||
      mimeType == 'image/gif' ||
      mimeType == 'image/webp';
}

class FileAttachmentPickResult {
  final List<FileAttachment> files;
  final List<String> tooLargeFileNames;
  final List<String> failedFileNames;

  const FileAttachmentPickResult({
    this.files = const [],
    this.tooLargeFileNames = const [],
    this.failedFileNames = const [],
  });
}

String mimeTypeForFileName(String fileName) {
  final extension = fileName.contains('.')
      ? fileName.split('.').last.toLowerCase()
      : '';
  return switch (extension) {
    'txt' || 'log' => 'text/plain',
    'md' || 'markdown' => 'text/markdown',
    'html' || 'htm' => 'text/html',
    'css' => 'text/css',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'xml' => 'application/xml',
    'yaml' || 'yml' => 'application/yaml',
    'pdf' => 'application/pdf',
    'zip' => 'application/zip',
    'gz' => 'application/gzip',
    'tar' => 'application/x-tar',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    _ => 'application/octet-stream',
  };
}
