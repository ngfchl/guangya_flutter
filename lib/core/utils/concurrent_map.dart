/// Runs [action] for [values] with a bounded number of in-flight operations.
///
/// Results preserve input order. Once an operation fails, workers finish their
/// current operation but do not start additional work, then the first error is
/// rethrown with its original stack trace.
Future<List<R>> concurrentMapOrdered<T, R>(
  Iterable<T> values, {
  required int concurrency,
  required Future<R> Function(T value) action,
}) async {
  final items = values.toList(growable: false);
  if (items.isEmpty) return <R>[];

  final workerCount = concurrency.clamp(1, items.length);
  final results = List<Object?>.filled(items.length, null);
  var nextIndex = 0;
  Object? firstError;
  StackTrace? firstStackTrace;

  Future<void> worker() async {
    while (firstError == null && nextIndex < items.length) {
      final index = nextIndex++;
      try {
        results[index] = await action(items[index]);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
  }

  await Future.wait(List.generate(workerCount, (_) => worker()));
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStackTrace!);
  }
  return List<R>.generate(items.length, (index) => results[index] as R);
}
