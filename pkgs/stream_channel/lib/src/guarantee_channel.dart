// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:async/async.dart';

import '../stream_channel.dart';

/// A [StreamChannel] that enforces the stream channel guarantees.
///
/// This is exposed via [new StreamChannel.withGuarantees].
class GuaranteeChannel<T> extends StreamChannelMixin<T> {
  Stream<T> get stream => _streamController.stream;

  StreamSink<T> get sink => _sink;
  _GuaranteeSink<T> _sink;

  /// The controller for [stream].
  ///
  /// This intermediate controller allows us to continue listening for a done
  /// event even after the user has canceled their subscription, and to send our
  /// own done event when the sink is closed.
  StreamController<T> _streamController;

  /// The subscription to the inner stream.
  StreamSubscription<T> _subscription;

  /// Whether the sink has closed, causing the underlying channel to disconnect.
  bool _disconnected = false;

  GuaranteeChannel(Stream<T> innerStream, StreamSink<T> innerSink) {
    _sink = new _GuaranteeSink<T>(innerSink, this);

    // Enforce the single-subscription guarantee by changing a broadcast stream
    // to single-subscription.
    if (innerStream.isBroadcast) {
      innerStream = innerStream.transform(
          const SingleSubscriptionTransformer());
    }

    _streamController = new StreamController<T>(onListen: () {
      // If the sink has disconnected, we've already called
      // [_streamController.close].
      if (_disconnected) return;

      _subscription = innerStream.listen(_streamController.add,
          onError: _streamController.addError,
          onDone: () {
            _sink._onStreamDisconnected();
            _streamController.close();
          });
    }, sync: true);
  }

  /// Called by [_GuaranteeSink] when the user closes it.
  ///
  /// The sink closing indicates that the connection is closed, so the stream
  /// should stop emitting events.
  void _onSinkDisconnected() {
    _disconnected = true;
    if (_subscription != null) _subscription.cancel();
    _streamController.close();
  }
}

/// The sink for [GuaranteeChannel].
///
/// This wraps the inner sink to ignore events and cancel any in-progress
/// [addStream] calls when the underlying channel closes.
class _GuaranteeSink<T> implements StreamSink<T> {
  /// The inner sink being wrapped.
  final StreamSink<T> _inner;

  /// The [GuaranteeChannel] this belongs to.
  final GuaranteeChannel<T> _channel;

  Future get done => _inner.done;

  /// Whether the stream has emitted a done event, causing the underlying
  /// channel to disconnect.
  bool _disconnected = false;

  /// Whether the user has called [close].
  bool _closed = false;

  /// The subscription to the stream passed to [addStream], if a stream is
  /// currently being added.
  StreamSubscription<T> _addStreamSubscription;

  /// The completer for the future returned by [addStream], if a stream is
  /// currently being added.
  Completer _addStreamCompleter;

  /// Whether we're currently adding a stream with [addStream].
  bool get _inAddStream => _addStreamSubscription != null;

  _GuaranteeSink(this._inner, this._channel);

  void add(T data) {
    if (_closed) throw new StateError("Cannot add event after closing.");
    if (_inAddStream) {
      throw new StateError("Cannot add event while adding stream.");
    }
    if (_disconnected) return;

    _inner.add(data);
  }

  void addError(error, [StackTrace stackTrace]) {
    if (_closed) throw new StateError("Cannot add event after closing.");
    if (_inAddStream) {
      throw new StateError("Cannot add event while adding stream.");
    }
    if (_disconnected) return;

    _inner.addError(error, stackTrace);
  }

  Future addStream(Stream<T> stream) {
    if (_closed) throw new StateError("Cannot add stream after closing.");
    if (_inAddStream) {
      throw new StateError("Cannot add stream while adding stream.");
    }
    if (_disconnected) return new Future.value();

    _addStreamCompleter = new Completer.sync();
    _addStreamSubscription = stream.listen(
        _inner.add,
        onError: _inner.addError,
        onDone: _addStreamCompleter.complete);
    return _addStreamCompleter.future.then((_) {
      _addStreamCompleter = null;
      _addStreamSubscription = null;
    });
  }

  Future close() {
    if (_inAddStream) {
      throw new StateError("Cannot close sink while adding stream.");
    }

    _closed = true;
    if (_disconnected) return new Future.value();

    _channel._onSinkDisconnected();
    return _inner.close();
  }

  /// Called by [GuaranteeChannel] when the stream emits a done event.
  ///
  /// The stream being done indicates that the connection is closed, so the
  /// sink should stop forwarding events.
  void _onStreamDisconnected() {
    _disconnected = true;
    if (!_inAddStream) return;

    _addStreamCompleter.complete(_addStreamSubscription.cancel());
    _addStreamCompleter = null;
    _addStreamSubscription = null;
  }
}
