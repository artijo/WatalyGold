import 'dart:async';
import 'package:flutter/foundation.dart';

/// Singleton class to manage Gemini API rate limiting
class GeminiRateLimiter {
  static final GeminiRateLimiter _instance = GeminiRateLimiter._internal();

  factory GeminiRateLimiter() => _instance;

  GeminiRateLimiter._internal();

  final List<Future<void>> _requestQueue = [];
  bool _isProcessing = false;
  DateTime? _lastRequestTime;
  static const int _minDelayBetweenRequests = 2000; // 2 seconds
  static const int _maxConcurrentRequests = 1; // Only 1 concurrent request

  /// Add a request to the queue and execute it when ready
  Future<T> executeRequest<T>(Future<T> Function() request) async {
    final completer = Completer<T>();

    // Add to queue
    _requestQueue.add(_processRequest(request, completer));

    // Start processing if not already doing so
    if (!_isProcessing) {
      _processQueue();
    }

    return completer.future;
  }

  Future<void> _processRequest<T>(
      Future<T> Function() request, Completer<T> completer) async {
    try {
      // Ensure minimum delay between requests
      if (_lastRequestTime != null) {
        final timeSinceLastRequest = DateTime.now().millisecondsSinceEpoch -
            _lastRequestTime!.millisecondsSinceEpoch;

        if (timeSinceLastRequest < _minDelayBetweenRequests) {
          final delayNeeded = _minDelayBetweenRequests - timeSinceLastRequest;
          debugPrint(
              'GeminiRateLimiter: Waiting ${delayNeeded}ms before next request');
          await Future.delayed(Duration(milliseconds: delayNeeded));
        }
      }

      debugPrint('GeminiRateLimiter: Executing request');
      _lastRequestTime = DateTime.now();

      final result = await request();
      completer.complete(result);
    } catch (error) {
      debugPrint('GeminiRateLimiter: Request failed: $error');
      completer.completeError(error);
    }
  }

  Future<void> _processQueue() async {
    _isProcessing = true;

    while (_requestQueue.isNotEmpty) {
      final currentBatch = _requestQueue.take(_maxConcurrentRequests).toList();
      _requestQueue.removeRange(0, currentBatch.length);

      // Process current batch
      await Future.wait(currentBatch);
    }

    _isProcessing = false;
  }

  /// Get current queue length for debugging
  int get queueLength => _requestQueue.length;

  /// Clear all pending requests (emergency stop)
  void clearQueue() {
    _requestQueue.clear();
    _isProcessing = false;
    debugPrint('GeminiRateLimiter: Queue cleared');
  }
}
