library sequence;

import 'dart:async';
import 'dart:math';
import 'dart:collection';
import 'package:meta/meta.dart';
import 'package:dart_extensions/dart_extensions.dart';

part 'sequence_settings.dart';

enum SequenceState { IDLE, IN_PROGRESS, SUCCEEDED, FAILED }

enum SequenceUpdateType { SEQUENCE_START, STAGE_START, STAGE_END, SEQUENCE_END }

abstract class Sequence<STAGE_TYPE> {
  String? _name;
  String? get name => _name;
  List<Stage<STAGE_TYPE>> _stages = [];
  List<Stage<STAGE_TYPE>> get stages => _stages;
  bool? _logger;
  final Inbox _inbox = Inbox();

  final StreamController<SequenceUpdate<STAGE_TYPE>> _streamController =
      StreamController<SequenceUpdate<STAGE_TYPE>>.broadcast();

  Stream<SequenceUpdate<STAGE_TYPE>> get stream => _streamController.stream;

  Completer _sequenceStartCompleter = Completer();

  Future get sequenceStart => _sequenceStartCompleter.future;

  Stage<STAGE_TYPE>? _currStage;

  Stage<STAGE_TYPE>? get currStage => _currStage;

  Stage<STAGE_TYPE>? get prevStage => stageBefore(currStage?.name);

  Stage<STAGE_TYPE>? get nextStage => stageAfter(currStage?.name);

  Stage<STAGE_TYPE>? stageBefore(STAGE_TYPE? stage) {
    if (stage == null) return null;
    int stageIndex = _stages.map((stage) => stage.name).toList().indexOf(stage);
    return (stageIndex > 0) ? _stages[stageIndex - 1] : null;
  }

  Stage<STAGE_TYPE>? stageAfter(STAGE_TYPE? stage) {
    if (stage == null) return null;
    int stageIndex = _stages.map((stage) => stage.name).toList().indexOf(stage);
    return (stageIndex < _stages.length - 1) ? _stages[stageIndex + 1] : null;
  }

  int stagePosition(STAGE_TYPE stageName) => _stages.indexWhere((stage) => stage.name == stageName);

  STAGE_TYPE stageName(int position) => _stages[position].name;

  List<SequenceUpdate<STAGE_TYPE>> _sequenceUpdates = [];

  UnmodifiableListView<SequenceUpdate<STAGE_TYPE>> get sequenceUpdates => UnmodifiableListView(_sequenceUpdates);

  SequenceState _state = SequenceState.IDLE;

  SequenceState get state => _state;

  void _setState(SequenceState state) => _state = state;

  bool isState(SequenceState state) => _state == state;

  bool get isIdle => isState(SequenceState.IDLE);

  bool get isInProgress => isState(SequenceState.IN_PROGRESS);

  bool get isDone => isState(SequenceState.SUCCEEDED) || isState(SequenceState.FAILED);

  bool get isDoneSucceeded => isState(SequenceState.SUCCEEDED);

  bool get isDoneFailed => isState(SequenceState.FAILED);

  List<void Function()> _onStartFunctions = [];
  List<void Function()> _onSuccessFunctions = [];
  List<void Function()> _onFailFunctions = [];
  List<void Function(bool)> _onDoneFunctions = [];

  Sequence() {
    SequenceSettings<STAGE_TYPE> settings = init();
    customize(settings);
    _name = settings.name;
    _stages.addAll(settings.stages);
    _logger = settings.logger;
    _stages.forEach((stage) {
      stage.inbox = _inbox;
      stage.action.timeoutDuration ??= settings.actionTimeoutDuration;
    });
    _onStartFunctions.addIfNotNull(settings.onStart);
     _onSuccessFunctions.addIfNotNull(settings.onSuccess);
    _onFailFunctions.addIfNotNull(settings.onFail);
    _onDoneFunctions.addIfNotNull(settings.onDone);
  }

  SequenceSettings<STAGE_TYPE> init();

  @visibleForOverriding
  void customize(SequenceSettings settings) => null;

  T start<T extends Sequence<STAGE_TYPE>>({STAGE_TYPE? from, STAGE_TYPE? until}) {
    if (!isState(SequenceState.IDLE)) throw '[$name] Can\'t start a sequence that has already been started';
    _sequenceStartCompleter.complete();
    _streamController.addStream(_start(from, until)).then((_) => _streamController.close());
    return this as T;
  }

  void listen(Function(SequenceUpdate) onUpdate) {
    StreamSubscription? sub;
    sub = stream.listen((sequenceUpdate) {
      onUpdate(sequenceUpdate);
    }, onDone: () {
      sub?.cancel();
    });
  }

  void onUpdate({
    SequenceUpdateType? type,
    STAGE_TYPE? stage,
    bool? success,
    required Function(SequenceUpdate) callback,
  }) {
    listen((sequenceUpdate) {
      bool typeCondition = type != null ? (sequenceUpdate.type == type) : true;
      bool stageCondition = stage != null ? (sequenceUpdate.stage == stage) : true;
      bool successCondition = success != null ? (sequenceUpdate.success == success) : true;
      if (typeCondition && stageCondition && successCondition) {
        callback(sequenceUpdate);
      }
    });
  }

  void onStart(void Function() callback) => _onStartFunctions.add(callback);

  void onSuccess(void Function() callback) => _onSuccessFunctions.add(callback);

  void onFail(void Function() callback) => _onFailFunctions.add(callback);

  void onDone(void Function(bool) callback) => _onDoneFunctions.add(callback);

  Future<SequenceUpdate<STAGE_TYPE>?> waitFor({SequenceUpdateType? type, STAGE_TYPE? stage, bool? success}) async =>
      await stream.firstWhereX((sequenceUpdate) {
        bool typeCondition = type != null ? (sequenceUpdate.type == type) : true;
        bool stageCondition = stage != null ? (sequenceUpdate.stage == stage) : true;
        bool successCondition = success != null ? (sequenceUpdate.success == success) : true;
        return (typeCondition && stageCondition && successCondition);
      });

  Future<SequenceUpdate<STAGE_TYPE>?> waitForSequenceEnd() async => await waitFor(type: SequenceUpdateType.SEQUENCE_END);

  Sequence leaveMessage(InboxMessage message) {
    _inbox._streamController.add(message);
    return this;
  }

  Sequence requestSkip() => leaveMessage(InboxMessage.SKIP);

  Sequence requestStop() => leaveMessage(InboxMessage.STOP);

  Sequence forwardInbox(Inbox inbox) {
    inbox._stream.forEach((message) => leaveMessage(message));
    return this;
  }

  SequenceUpdate<STAGE_TYPE> _safeUpdate(SequenceUpdate<STAGE_TYPE> sequenceUpdate,
      [Function(SequenceUpdate<STAGE_TYPE> update)? callback]) {
    _sequenceUpdates.add(sequenceUpdate);
    callback?.call(sequenceUpdate);
    _log(sequenceUpdate);
    return sequenceUpdate;
  }

  Stream<SequenceUpdate<STAGE_TYPE>> _start(STAGE_TYPE? from, STAGE_TYPE? until) async* {
    int k = from != null ? (_stages.indexWhere((stage) => stage.name == from)) : 0;
    int n = until != null ? (_stages.indexWhere((stage) => stage.name == until)) : (_stages.length) - 1;
    yield _safeUpdate(
      SequenceUpdate(
        type: SequenceUpdateType.SEQUENCE_START,
      ),
      (update) {
        _setState(SequenceState.IN_PROGRESS);
        _onStartFunctions.forEach((fun) => fun());
      },
    );

    yield* _startStage(k, n);
  }

  Stream<SequenceUpdate<STAGE_TYPE>> _startStage(int k, int n) async* {
    _currStage = _stages[k];
    yield _safeUpdate(
      SequenceUpdate(
        type: SequenceUpdateType.STAGE_START,
        stage: _stages[k].name,
      ),
    );

    Result<STAGE_TYPE> result = await _stages[k].act();

    yield _safeUpdate(
      SequenceUpdate(
        type: SequenceUpdateType.STAGE_END,
        stage: _stages[k].name,
        success: result.succeeded,
        extra: result.extra,
      ),
    );

    int stageToJumpTo;
    if (result.endSequence!)
      stageToJumpTo = n + 1;
    else if (result._jumpBack != null)
      stageToJumpTo = max(0, k - result._jumpBack!);
    else if (result._jumpForward != null)
      stageToJumpTo = k + result._jumpForward!;
    else if (result._jumpTo != null)
      stageToJumpTo = (_stages.indexWhere((stage) => stage.name == result._jumpTo));
    else
      stageToJumpTo = k + 1;
    if (stageToJumpTo <= n)
      yield* _startStage(stageToJumpTo, n);
    else {
      yield _safeUpdate(
          SequenceUpdate(
            type: SequenceUpdateType.SEQUENCE_END,
            success: result.succeeded,
            extra: result.extra,
          ), (update) {
        if (update.success!) {
          _setState(SequenceState.SUCCEEDED);
          _onSuccessFunctions.forEach((fun) => fun());
        }
        if (!update.success!) {
          _setState(SequenceState.FAILED);
          _onFailFunctions.forEach((fun) => fun());
        }
        _onDoneFunctions.forEach((fun) => fun(update.success!));
        _inbox.close();
      });
    }
  }

  _log(SequenceUpdate update) {
    if (_logger!) {
      SequenceUpdateType type = update.type;
      STAGE_TYPE? stage = update.stage;
      bool? success = update.success;
      String str;
      str = 'Sequence Handler [$name]: ';
      String typeStr = type.toString().split('.').last;
      str += '($typeStr) ';
      if (stage != null) {
        String stageStr = stage.toString().split('.').last;
        str += '$stageStr ';
      }
      if (success != null) {
        str += '(${success ? 'SUCCESS' : 'FAIL'}) ';
      }
      print(str);
    }
  }
}

class Stage<STAGE_TYPE> {
  final STAGE_TYPE name;
  final Action<STAGE_TYPE> action;
  late Inbox inbox;

  Stage({
    required this.name,
    required this.action,
  });

  Future<Result<STAGE_TYPE>> act() async {
    Future<Result<STAGE_TYPE>> future = action.function(Result<STAGE_TYPE>(), action.arguments, inbox);
    if (action.timeoutDuration != null)
      future = future.timeout(action.timeoutDuration!, onTimeout: () => Result<STAGE_TYPE>()..fail());
    return await future;
  }

// operator == (stage) => (this.name == stage.name) && (this.action.function == stage.action.function);
}

typedef StageFunction<T> = Future<Result<T>> Function(Result<T> result, Map<String, dynamic> args, Inbox inbox);

class Action<STAGE_TYPE> {
  final StageFunction<STAGE_TYPE> function;
  final Map<String, dynamic> arguments;
  Duration? timeoutDuration;

  Action(this.function, {this.arguments = const {}, this.timeoutDuration});
}

class Result<STAGE_TYPE> {
  bool? succeeded;
  dynamic extra;
  int? _jumpBack;
  int? _jumpForward;
  STAGE_TYPE? _jumpTo;
  bool? endSequence;

  success([dynamic _extra]) {
    succeeded = true;
    extra = _extra;
    endSequence = false;
    return this;
  }

  fail([dynamic _extra]) {
    succeeded = false;
    extra = _extra;
    endSequence = true;
    return this;
  }

  jumpBack({required int stages, required bool success, dynamic extra}) {
    succeeded = success;
    this.extra = extra;
    _jumpBack = stages;
    endSequence = false;
    return this;
  }

  jumpForward({required int stages, required bool success, dynamic extra}) {
    succeeded = success;
    this.extra = extra;
    _jumpForward = stages;
    endSequence = false;
    return this;
  }

  jumpTo({required STAGE_TYPE stage, required bool success, dynamic extra}) {
    succeeded = success;
    this.extra = extra;
    _jumpTo = stage;
    endSequence = false;
    return this;
  }

  endSequenceOnSuccess({dynamic extra}) {
    succeeded = true;
    this.extra = extra;
    endSequence = true;
    return this;
  }
}

class SequenceUpdate<STAGE_TYPE> {
  final SequenceUpdateType type;
  final STAGE_TYPE? stage;
  final bool? success;
  final dynamic extra;

  SequenceUpdate({
    required this.type,
    this.stage,
    this.success,
    this.extra,
  }) {
    if (type == SequenceUpdateType.SEQUENCE_START || type == SequenceUpdateType.SEQUENCE_END) {
      if (stage != null) {
        /// throw error - sequence start and end aren't a stage
      }
    }
    if (type == SequenceUpdateType.SEQUENCE_START || type == SequenceUpdateType.STAGE_START) {
      if (success != null) {
        /// throw error - sequence start and stage start don't have results
      }
    }
  }

  @override
  String toString() => 'type: [$type] stage: [$stage] success: [$success] extra: [$extra]';

  @override
  bool operator ==(other) => (other is SequenceUpdate<STAGE_TYPE> &&
      type == other.type &&
      stage == other.stage &&
      success == other.success &&
      extra == other.extra);

  @override
  int get hashCode => (((type.hashCode ^ (stage.hashCode)) ^ success.hashCode) ^ extra.hashCode);
}

enum InboxMessage { SKIP, STOP }

class Inbox {
  StreamController<InboxMessage> _streamController = StreamController<InboxMessage>.broadcast();

  Stream<InboxMessage> get _stream => _streamController.stream;
  bool _skip = false;
  bool _stop = false;

  Inbox() {
    listen((message) {
      switch (message) {
        case InboxMessage.SKIP:
          _skip = true;
          break;
        case InboxMessage.STOP:
          _stop = true;
          break;
      }
    });
  }

  bool checkSkip({bool reset = true}) {
    bool skip = _skip;
    if (reset) _skip = false;
    return skip;
  }

  bool checkStop({bool reset = true}) {
    bool stop = _stop;
    if (reset) _stop = false;
    return stop;
  }

  StreamSubscription listen(void Function(InboxMessage message) onMessage) => _stream.listen(onMessage);

  Future<void> waitForSkip({bool reset = true}) async =>
      await _stream.firstWhere((message) => message == InboxMessage.SKIP).then((_) => checkSkip(reset: reset));

  Future<void> waitForStop({bool reset = true}) async =>
      await _stream.firstWhere((message) => message == InboxMessage.STOP).then((_) => checkStop(reset: reset));

  void close() {
    _streamController.close();
  }
}

extension CheckInbox<T> on Future<T> {
  Future<T> checkInbox(
    Inbox inbox, {
    void Function(InboxMessage message)? onMessage,
    bool completeOnMessage = false,
  }) {
    int rand = Random().nextInt(500);
    Completer<T> completer = Completer<T>();
    StreamSubscription sub = inbox.listen((message) {
      onMessage?.call(message);
      print('($rand) onMessage');
      if (completeOnMessage) completer.complete(null);
    });
    then((v) {
      print('($rand) then');
      sub.cancel();
      completer.complete(v);
    });
    return completer.future;
  }

  Future<T> checkInboxForStopRequest(
    Inbox inbox, {
    void Function()? onStopMessage,
    bool completeOnMessage = false,
  }) =>
      checkInbox(inbox, onMessage: (message) {
        if (message == InboxMessage.STOP) onStopMessage?.call();
      }, completeOnMessage: completeOnMessage);
}
