import 'package:flutter_test/flutter_test.dart';
import 'package:guangya_flutter/providers/file_provider.dart';

void main() {
  test('UploadProgress reports byte-based progress when bytes are known', () {
    const progress = UploadProgress(
      totalFiles: 3,
      completedFiles: 1,
      failedFiles: 0,
      totalBytes: 400,
      transferredBytes: 100,
      currentFileName: 'movie.mkv',
      isActive: true,
    );

    expect(progress.processedFiles, 1);
    expect(progress.fraction, 0.25);
  });

  test('UploadProgress falls back to processed files for empty files', () {
    const progress = UploadProgress(
      totalFiles: 2,
      completedFiles: 1,
      failedFiles: 1,
      totalBytes: 0,
      transferredBytes: 0,
      currentFileName: '',
      isActive: false,
    );

    expect(progress.processedFiles, 2);
    expect(progress.fraction, 1);
  });
}
