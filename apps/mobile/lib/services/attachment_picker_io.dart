import 'dart:io';

import 'package:flutter/services.dart';

import '../models/file_attachment.dart';

const _filePickerChannel = MethodChannel('ccpocket/file_picker');

Future<FileAttachmentPickResult> pickFileAttachments({
  required int maxFiles,
}) async {
  if (!Platform.isMacOS || maxFiles <= 0) {
    return const FileAttachmentPickResult();
  }

  final paths = await _filePickerChannel.invokeListMethod<String>('pickFiles', {
    'maxFiles': maxFiles,
  });
  if (paths == null || paths.isEmpty) {
    return const FileAttachmentPickResult();
  }

  final files = <FileAttachment>[];
  final tooLargeFileNames = <String>[];
  final failedFileNames = <String>[];

  for (final path in paths.take(maxFiles)) {
    final name = path.split(Platform.pathSeparator).last;
    try {
      final file = File(path);
      final length = await file.length();
      if (length > maxFileAttachmentBytes) {
        tooLargeFileNames.add(name);
        continue;
      }
      files.add(
        FileAttachment(
          name: name,
          mimeType: mimeTypeForFileName(name),
          bytes: await file.readAsBytes(),
        ),
      );
    } catch (_) {
      failedFileNames.add(name);
    }
  }

  return FileAttachmentPickResult(
    files: files,
    tooLargeFileNames: tooLargeFileNames,
    failedFileNames: failedFileNames,
  );
}
