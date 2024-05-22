part of sequence;

class SequenceSettings<T> {
  String name;
  final List<Stage<T>> stages;
  final Duration? actionTimeoutDuration;
  final bool logger;
  final void Function()? onStart;
  final void Function()? onSuccess;
  final void Function()? onFail;
  final void Function(bool)? onDone;

  SequenceSettings({
    this.name = 'unnamed',
    required this.stages,
    this.actionTimeoutDuration,
    this.logger = true,
    this.onStart,
    this.onSuccess,
    this.onFail,
    this.onDone,
  });
}
