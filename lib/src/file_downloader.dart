import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'base_downloader.dart';
import 'database.dart';
import 'models.dart';

/// Provides access to all functions of the plugin in a single place.
class FileDownloader {
  final _log = Logger('FileDownloader');
  static final FileDownloader _singleton = FileDownloader._internal();

  /// If no group is specified the default group name will be used
  static const defaultGroup = 'default';

  /// Calls to [download], [upload], [downloadBatch] and [uploadBatch] are
  /// monitored 'internally' in this special group
  static const awaitGroup = 'await';

  /// Database where tracked tasks are stored.
  ///
  /// Activate tracking by calling [trackTasks], and access the records in the
  /// database via this [database] object.
  final database = Database();

  final _taskCompleters = <Task, Completer<TaskStatus>>{};
  final _batches = <Batch>[];
  final _downloader = BaseDownloader.instance();

  /// Do not use: for testing only
  @visibleForTesting
  BaseDownloader get downloaderForTesting => _downloader;

  /// Registered short status callback for convenience down/upload tasks
  ///
  /// Short callbacks omit the [Task] as they are available from the closure
  final _shortTaskStatusCallbacks = <String, void Function(TaskStatus)>{};

  /// Registered short progress callback for convenience down/upload tasks
  ///
  /// Short callbacks omit the [Task] as they are available from the closure
  final _shortTaskProgressCallbacks = <String, void Function(double)>{};

  /// Registered [TaskStatusCallback] for convenience batch down/upload tasks
  final _taskStatusCallbacks = <String, TaskStatusCallback>{};

  /// Registered [TaskProgressCallback] for convenience batch down/upload tasks
  final _taskProgressCallbacks = <String, TaskProgressCallback>{};

  /// List of notification configurations
  final _notificationConfigs = <TaskNotificationConfig>[];

  factory FileDownloader() => _singleton;

  FileDownloader._internal();

  /// Stream of [TaskUpdate] updates for downloads that do
  /// not have a registered callback
  Stream<TaskUpdate> get updates => _downloader.updates.stream;

  /// Register status or progress callbacks to monitor download progress.
  ///
  /// Status callbacks are called only when the state changes, while
  /// progress callbacks are called to inform of intermediate progress.
  ///
  /// Different callbacks can be set for different groups, and the group
  /// can be passed on with the [DownloadTask] to ensure the
  /// appropriate callbacks are called for that group.
  ///
  /// Note that callbacks will be called based on a task's [updates]
  /// property, which defaults to status change callbacks only. To also get
  /// progress updates make sure to register a [TaskProgressCallback] and
  /// set the task's [updates] property to [Updates.progress] or
  /// [Updates.statusAndProgress].
  ///
  /// The call returns the [FileDownloader] to make chaining easier
  FileDownloader registerCallbacks(
      {String group = defaultGroup,
      TaskStatusCallback? taskStatusCallback,
      TaskProgressCallback? taskProgressCallback}) {
    assert(taskStatusCallback != null || (taskProgressCallback != null),
        'Must provide a TaskStatusCallback or a TaskProgressCallback, or both');
    if (taskStatusCallback != null) {
      _downloader.groupStatusCallbacks[group] = taskStatusCallback;
    }
    if (taskProgressCallback != null) {
      _downloader.groupProgressCallbacks[group] = taskProgressCallback;
    }
    return this; // makes chaining calls easier
  }

  /// Start a new task
  ///
  /// Returns true if successfully enqueued. A new task will also generate
  /// a [TaskStatus.enqueued] update to the registered callback,
  /// if requested by its [updates] property
  Future<bool> enqueue(Task task) =>
      _downloader.enqueue(task, _notificationConfigForTask(task));

  /// Download a file and return the final [TaskStatus]
  ///
  /// Different from [enqueue], this method does not return until the file
  /// has been downloaded, or an error has occurred.  While it uses the same
  /// download mechanism as [enqueue], and will execute the download also when
  /// the app moves to the background, it is meant for downloads that are
  /// awaited while the app is in the foreground.
  ///
  /// Optional callbacks for status and progress updates may be
  /// added. These function only take a [TaskStatus] or [double] argument as
  /// the task they refer to is expected to be captured in the closure for
  /// this call.
  /// For example `Downloader.download(task, onStatus: (status) =>`
  /// `print('Status for ${task.taskId} is $status);`
  ///
  /// Note that the task's [group] is ignored and will be replaced with an
  /// internal group name '_enqueueAndWait' to track status
  Future<TaskStatus> download(DownloadTask task,
          {void Function(TaskStatus)? onStatus,
          void Function(double)? onProgress}) =>
      _enqueueAndAwait(task, onStatus: onStatus, onProgress: onProgress);

  /// Upload a file and return the final [TaskStatus]
  ///
  /// Different from [enqueue], this method does not return until the file
  /// has been uploaded, or an error has occurred.  While it uses the same
  /// upload mechanism as [enqueue], and will execute the upload also when
  /// the app moves to the background, it is meant for uploads that are
  /// awaited while the app is in the foreground.
  ///
  /// Optional callbacks for status and progress updates may be
  /// added. These function only take a [TaskStatus] or [double] argument as
  /// the task they refer to is expected to be captured in the closure for
  /// this call.
  /// For example `Downloader.download(task, onStatus: (status) =>`
  /// `print('Status for ${task.taskId} is $status);`
  ///
  /// Note that the task's [group] is ignored and will be replaced with an
  /// internal group name 'await' to track status
  Future<TaskStatus> upload(UploadTask task,
          {void Function(TaskStatus)? onStatus,
          void Function(double)? onProgress}) =>
      _enqueueAndAwait(task, onStatus: onStatus, onProgress: onProgress);

  /// Enqueue the [task] and wait for completion
  ///
  /// Returns the final [TaskStatus] of the [task].
  /// This method is used to enqueue:
  /// 1. `download` and `upload` tasks, which may have a short callback
  ///    for status and progress (omitting Task)
  /// 2. `downloadBatch` and `uploadBatch`, which may have a full callback
  ///    that is used for every task in the batch
  Future<TaskStatus> _enqueueAndAwait(Task task,
      {void Function(TaskStatus)? onStatus,
      void Function(double)? onProgress,
      TaskStatusCallback? taskStatusCallback,
      TaskProgressCallback? taskProgressCallback}) async {
    /// Internal callback function that passes the update on to different
    /// callbacks
    ///
    /// The update is passed on to:
    /// 1. Task-specific callback, passed as parameter to call
    /// 2. Short task-specific callback, passed as parameter to call
    /// 3. Batch-related callback, if this task is part of a batch operation
    ///    and is in a final state
    ///
    /// If the task is in final state, also removes the reference to the
    /// task-specific callbacks and completes the completer associated
    /// with this task
    internalStatusCallback(Task task, TaskStatus status) {
      _shortTaskStatusCallbacks[task.taskId]?.call(status);
      _taskStatusCallbacks[task.taskId]?.call(task, status);
      if (status.isFinalState) {
        if (_batches.isNotEmpty) {
          // check if this task is part of a batch
          for (final batch in _batches) {
            if (batch.tasks.contains(task)) {
              batch.results[task] = status;
              if (batch.batchProgressCallback != null) {
                batch.batchProgressCallback!(
                    batch.numSucceeded, batch.numFailed);
              }
              break;
            }
          }
        }
        _shortTaskStatusCallbacks.remove(task.taskId);
        _shortTaskProgressCallbacks.remove(task.taskId);
        _taskStatusCallbacks.remove(task.taskId);
        _taskProgressCallbacks.remove(task.taskId);
        var taskCompleter = _taskCompleters.remove(task);
        taskCompleter?.complete(status);
      }
    }

    /// Internal callback function that only passes progress updates on
    /// to the task-specific progress callback passed as parameter to call
    internalProgressCallBack(Task task, double progress) {
      _shortTaskProgressCallbacks[task.taskId]?.call(progress);
      _taskProgressCallbacks[task.taskId]?.call(task, progress);
    }

    // register the internal callbacks and store the task-specific ones
    registerCallbacks(
        group: awaitGroup,
        taskStatusCallback: internalStatusCallback,
        taskProgressCallback: internalProgressCallBack);
    final internalTask = task.copyWith(
        group: awaitGroup,
        updates: (onProgress != null || taskProgressCallback != null)
            ? Updates.statusAndProgress
            : Updates.status);
    if (onStatus != null) {
      _shortTaskStatusCallbacks[task.taskId] = onStatus;
    }
    if (onProgress != null) {
      _shortTaskProgressCallbacks[task.taskId] = onProgress;
    }
    if (taskStatusCallback != null) {
      _taskStatusCallbacks[task.taskId] = taskStatusCallback;
    }
    if (taskProgressCallback != null) {
      _taskProgressCallbacks[task.taskId] = taskProgressCallback;
    }
    // Create taskCompleter and enqueue the task.
    // The completer will be completed in the internal status callback
    final taskCompleter = Completer<TaskStatus>();
    _taskCompleters[internalTask] = taskCompleter;
    final enqueueSuccess = await enqueue(internalTask);
    if (!enqueueSuccess) {
      _log.warning('Could not enqueue task $task}');
      return Future.value(TaskStatus.failed);
    }
    return taskCompleter.future;
  }

  /// Enqueues a list of files to download and returns when all downloads
  /// have finished (successfully or otherwise). The returned value is a
  /// [Batch] object that contains the original [tasks], the
  /// [results] and convenience getters to filter successful and failed results.
  ///
  /// If an optional [batchProgressCallback] function is provided, it will be
  /// called upon completion (successfully or otherwise) of each task in the
  /// batch, with two parameters: the number of succeeded and the number of
  /// failed tasks. The callback can be used, for instance, to show a progress
  /// indicator for the batch, where
  ///    double percent_complete = (succeeded + failed) / tasks.length
  ///
  /// To also monitor status and/or progress for each task in the batch, provide
  /// a [taskStatusCallback] and/or [taskProgressCallback], which will be used
  /// for each task in the batch.
  ///
  /// Note that to allow for special processing of tasks in a batch, the task's
  /// [Task.group] and [Task.updates] value will be modified when enqueued, and
  /// those modified tasks are returned as part of the [Batch]
  /// object.
  Future<Batch> downloadBatch(final List<DownloadTask> tasks,
          {BatchProgressCallback? batchProgressCallback,
          TaskStatusCallback? taskStatusCallback,
          TaskProgressCallback? taskProgressCallback}) =>
      _enqueueAndAwaitBatch(tasks,
          batchProgressCallback: batchProgressCallback,
          taskStatusCallback: taskStatusCallback,
          taskProgressCallback: taskProgressCallback);

  /// Enqueues a list of files to upload and returns when all uploads
  /// have finished (successfully or otherwise). The returned value is a
  /// [Batch] object that contains the original [tasks], the
  /// [results] and convenience getters to filter successful and failed results.
  ///
  /// If an optional [batchProgressCallback] function is provided, it will be
  /// called upon completion (successfully or otherwise) of each task in the
  /// batch, with two parameters: the number of succeeded and the number of
  /// failed tasks. The callback can be used, for instance, to show a progress
  /// indicator for the batch, where
  ///    double percent_complete = (succeeded + failed) / tasks.length
  ///
  /// To also monitor status and/or progress for each task in the batch, provide
  /// a [taskStatusCallback] and/or [taskProgressCallback], which will be used
  /// for each task in the batch.
  ///
  /// Note that to allow for special processing of tasks in a batch, the task's
  /// [Task.group] and [Task.updates] value will be modified when enqueued, and
  /// those modified tasks are returned as part of the [Batch]
  /// object.
  Future<Batch> uploadBatch(final List<UploadTask> tasks,
          {BatchProgressCallback? batchProgressCallback,
          TaskStatusCallback? taskStatusCallback,
          TaskProgressCallback? taskProgressCallback}) =>
      _enqueueAndAwaitBatch(tasks,
          batchProgressCallback: batchProgressCallback,
          taskStatusCallback: taskStatusCallback,
          taskProgressCallback: taskProgressCallback);

  /// Enqueue a list of tasks and wait for completion
  ///
  /// Returns a [Batch] object
  Future<Batch> _enqueueAndAwaitBatch(final List<Task> tasks,
      {BatchProgressCallback? batchProgressCallback,
      TaskStatusCallback? taskStatusCallback,
      TaskProgressCallback? taskProgressCallback}) async {
    assert(tasks.isNotEmpty, 'List of tasks cannot be empty');
    if (batchProgressCallback != null) {
      batchProgressCallback(0, 0); // initial callback
    }
    final batch = Batch(tasks, batchProgressCallback);
    _batches.add(batch);
    final taskFutures = <Future<TaskStatus>>[];
    var counter = 0;
    for (final task in tasks) {
      taskFutures.add(_enqueueAndAwait(task,
          taskStatusCallback: taskStatusCallback,
          taskProgressCallback: taskProgressCallback));
      counter++;
      if (counter % 3 == 0) {
        // To prevent blocking the UI we 'yield' for a few ms after every 3
        // tasks we enqueue
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    await Future.wait(taskFutures); // wait for all tasks to complete
    _batches.remove(batch);
    return batch;
  }

  /// Resets the downloader by cancelling all ongoing tasks within
  /// the provided [group]
  ///
  /// Returns the number of tasks cancelled. Every canceled task wil emit a
  /// [TaskStatus.canceled] update to the registered callback, if
  /// requested
  Future<int> reset({String group = defaultGroup}) => _downloader.reset(group);

  /// Returns a list of taskIds of all tasks currently active in this [group]
  ///
  /// Active means enqueued or running, and if [includeTasksWaitingToRetry] is
  /// true also tasks that are waiting to be retried
  Future<List<String>> allTaskIds(
          {String group = defaultGroup,
          bool includeTasksWaitingToRetry = true}) async =>
      (await allTasks(
              group: group,
              includeTasksWaitingToRetry: includeTasksWaitingToRetry))
          .map((task) => task.taskId)
          .toList();

  /// Returns a list of all tasks currently active in this [group]
  ///
  /// Active means enqueued or running, and if [includeTasksWaitingToRetry] is
  /// true also tasks that are waiting to be retried
  Future<List<Task>> allTasks(
          {String group = defaultGroup,
          bool includeTasksWaitingToRetry = true}) =>
      _downloader.allTasks(group, includeTasksWaitingToRetry);

  /// Cancel all tasks matching the taskIds in the list
  ///
  /// Every canceled task wil emit a [TaskStatus.canceled] update to
  /// the registered callback, if requested
  Future<bool> cancelTasksWithIds(List<String> taskIds) =>
      _downloader.cancelTasksWithIds(taskIds);

  /// Cancel this task
  ///
  /// The task will emit a [TaskStatus.canceled] update to
  /// the registered callback, if requested
  Future<bool> cancelTaskWithId(String taskId) => cancelTasksWithIds([taskId]);

  /// Return [Task] for the given [taskId], or null
  /// if not found.
  ///
  /// Only running tasks are guaranteed to be returned, but returning a task
  /// does not guarantee that the task is still running. To keep track of
  /// the status of tasks, use a [TaskStatusCallback]
  Future<Task?> taskForId(String taskId) => _downloader.taskForId(taskId);

  /// Activate tracking for tasks in this [group]
  ///
  /// All subsequent tasks in this group will be recorded in persistent storage.
  /// Use the [FileDownloader.database] to get or remove [TaskRecord] objects,
  /// which contain a [Task], its [TaskStatus] and a [double] for progress.
  ///
  /// If [markDownloadedComplete] is true (default) then all tasks in the
  /// database that are marked as not yet [TaskStatus.complete] will be set to
  /// [TaskStatus.complete] if the target file for that task exists.
  /// They will also emit [TaskStatus.complete] and [progressComplete] to
  /// their registered listener or callback.
  /// This is a convenient way to capture downloads that have completed while
  /// the app was suspended: on app startup, immediately register your
  /// listener or callbacks, and call [trackTasks] fro each group.
  Future<void> trackTasks(
          {String group = defaultGroup, bool markDownloadedComplete = true}) =>
      _downloader.trackTasks(group, markDownloadedComplete);

  /// Wakes up the FileDownloader from possible background state, triggering
  /// a stream of updates that may have been processed while in the background,
  /// and have not yet reached the callbacks or listener
  ///
  /// Calling this method multiple times has no effect.
  Future<void> resumeFromBackground() =>
      _downloader.retrieveLocallyStoredData();

  /// Returns true if task can be resumed on pause
  ///
  /// This future only completes once the task is running and has received
  /// information from the server to determine whether resume is possible.
  /// If the [Task.allowPause] field is set to false (default) then
  /// this method returns false immediately.
  Future<bool> taskCanResume(Task task) => _downloader.taskCanResume(task);

  /// Pause the task
  ///
  /// Returns true if the pause was attempted successfully. Test the task's
  /// status to see if it was executed successfully [TaskStatus.paused] or if
  /// it failed after all [TaskStatus.failed]
  ///
  /// If the [Task.allowPause] field is set to false (default) or if this is
  /// a POST request, this method returns false immediately.
  Future<bool> pause(DownloadTask task) async {
    if (task.allowPause && task.post == null) {
      return _downloader.pause(task);
    }
    return false;
  }

  /// Resume the task
  ///
  /// Returns true if the pause was attempted successfully. Status will change
  /// similar to a call to [enqueue]. If the task is able to resume, it will,
  /// otherwise it will restart the task from scratch.
  ///
  /// If the [Task.allowPause] field is set to false (default) or if this is
  /// a POST request, this method returns false immediately.
  Future<bool> resume(DownloadTask task) async {
    if (task.allowPause && task.post == null) {
      return _downloader.resume(task, _notificationConfigForTask(task));
    }
    return false;
  }

  /// Configure notification for a single task
  FileDownloader configureNotificationForTask(Task task,
      {TaskNotification? runningNotification,
      TaskNotification? completeNotification,
      TaskNotification? errorNotification,
      TaskNotification? pausedNotification,
      bool progressBar = false}) {
    _notificationConfigs.add(TaskNotificationConfig(
        taskOrGroup: task,
        running: runningNotification,
        complete: completeNotification,
        error: errorNotification,
        paused: pausedNotification,
        progressBar: progressBar));
    return this;
  }

  /// Configure notification for a group of tasks
  FileDownloader configureNotificationForGroup(String group,
      {TaskNotification? runningNotification,
      TaskNotification? completeNotification,
      TaskNotification? errorNotification,
      TaskNotification? pausedNotification,
      bool progressBar = false}) {
    _notificationConfigs.add(TaskNotificationConfig(
        taskOrGroup: group,
        running: runningNotification,
        complete: completeNotification,
        error: errorNotification,
        paused: pausedNotification,
        progressBar: progressBar));
    return this;
  }

  /// Configure default task notification
  ///
  /// This is the notification configuration used for tasks that do not
  /// match a task-specific or group-specific notification configuration
  FileDownloader configureNotification(
      {TaskNotification? running,
      TaskNotification? complete,
      TaskNotification? error,
      TaskNotification? paused,
      bool progressBar = false}) {
    _notificationConfigs.add(TaskNotificationConfig(
        taskOrGroup: null,
        running: running,
        complete: complete,
        error: error,
        paused: paused,
        progressBar: progressBar));
    return this;
  }

  /// Returns the [TaskNotificationConfig] for this [task] or null
  ///
  /// Matches on task, then on group, then on default
  TaskNotificationConfig? _notificationConfigForTask(Task task) {
    return _notificationConfigs
            .firstWhereOrNull((config) => config.taskOrGroup == task) ??
        _notificationConfigs
            .firstWhereOrNull((config) => config.taskOrGroup == task.group) ??
        _notificationConfigs
            .firstWhereOrNull((config) => config.taskOrGroup == null);
  }

  /// Perform a server request for this [request]
  ///
  /// A server request returns an [http.Response] object that includes
  /// the [body] as String, the [bodyBytes] as [UInt8List] and the [json]
  /// representation if available.
  /// It also contains the [statusCode] and [reasonPhrase] that may indicate
  /// an error, and several other fields that may be useful.
  /// A local error (e.g. a SocketException) will yield [statusCode] 499, with
  /// details in the [reasonPhrase]
  ///
  /// The request will abide by the [retries] set on the [request], and set
  /// [headers] included in the [request]
  ///
  /// The [http.Client] object used for this request is the [httpClient] field of
  /// the downloader. If not set, the default [http.Client] will be used.
  /// The request is executed on an Isolate, to ensure minimal interference
  /// with the main Isolate
  Future<http.Response> request(Request request) => compute(doRequest, request);

  /// Move the file represented by the [task] to a shared storage
  /// [destination] and potentially a [directory] within that destination. If
  /// the [mimeType] is not provided we will attempt to derive it from the
  /// [filePath] extension
  ///
  /// Returns the path to the stored file, or null if not successful
  ///
  /// Platform-dependent, not consistent across all platforms
  Future<String?> moveToSharedStorage(
    DownloadTask task,
    SharedStorage destination, {
    String directory = '',
    String? mimeType,
  }) async =>
      moveFileToSharedStorage(await task.filePath(), destination,
          directory: directory, mimeType: mimeType);

  /// Move the file represented by [filePath] to a shared storage
  /// [destination] and potentially a [directory] within that destination. If
  /// the [mimeType] is not provided we will attempt to derive it from the
  /// [filePath] extension
  ///
  /// Returns the path to the stored file, or null if not successful
  ///
  /// Platform-dependent, not consistent across all platforms
  Future<String?> moveFileToSharedStorage(
    String filePath,
    SharedStorage destination, {
    String directory = '',
    String? mimeType,
  }) async =>
      _downloader.moveToSharedStorage(
          filePath, destination, directory, mimeType);

  /// Destroy the [FileDownloader]. Subsequent use requires initialization
  void destroy() {
    _batches.clear();
    _taskCompleters.clear();
    _shortTaskStatusCallbacks.clear();
    _shortTaskProgressCallbacks.clear();
    _taskStatusCallbacks.clear();
    _taskProgressCallbacks.clear();
    _notificationConfigs.clear();
    _downloader.destroy();
  }
}

/// Performs the actual server request, with retries
///
/// This function is run on an Isolate to ensure performance on the main
/// Isolate is not affected
Future<http.Response> doRequest(Request request) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    if (kDebugMode) {
      print('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    }
  });
  final log = Logger('FileDownloader.request');
  final client = http.Client();
  var response = http.Response('', 499,
      reasonPhrase: 'Not attempted'); // dummy to start with
  while (request.retriesRemaining >= 0) {
    try {
      response = request.post == null
          ? await client.get(Uri.parse(request.url), headers: request.headers)
          : await client.post(Uri.parse(request.url),
              headers: request.headers, body: request.post);
      if ([200, 201, 202, 203, 204, 205, 206, 404]
          .contains(response.statusCode)) {
        return response;
      }
    } catch (e) {
      log.warning(e);
      response = http.Response('', 499, reasonPhrase: e.toString());
    }
    // error, retry if allowed
    request.decreaseRetriesRemaining();
    if (request.retriesRemaining < 0) {
      return response; // final response with error
    }
    final waitTime = Duration(
        seconds: pow(2, (request.retries - request.retriesRemaining)).toInt());
    await Future.delayed(waitTime);
  }
  throw ArgumentError('Request to ${request.url} had no retries remaining');
}
