// lib/services/control_service.dart
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'convo_master.dart';
import 'sleep_service.dart';
import '../agents/agent_manager.dart';

/// Internal control message object
class _CtrlMsg {
  final String type;     // 'wake', 'sleep', 'agent', 'reset'
  final String? payload;
  _CtrlMsg(this.type, [this.payload]);
}

/// ------------------------------------------------------
/// ControlService
/// Tablet → Millie over HTTP
/// ------------------------------------------------------
class ControlService {
  static Future<void> start(
    ConvoMaster cm, {
    int port = 5000,
  }) async {
    final receive = ReceivePort();

    receive.listen((msg) async {
      if (msg is! _CtrlMsg) return;

      switch (msg.type) {
        case 'wake':
          cm.onStatus?.call('[Control] wake command received');

          if (!cm.isRunning) {
            await cm.start();
          } else {
            cm.onStatus?.call('[Control] wake ignored (already running)');
          }
          break;

        case 'sleep':
          cm.onStatus?.call('[Control] sleep command received');

          if (cm.isRunning) {
            await SleepService.triggerSleep(cm);
          } else {
            cm.onStatus?.call('[Control] sleep ignored (not running)');
          }
          break;

        case 'agent':
          final agent = msg.payload ?? 'default';
          AgentManager.instance.setActive(agent);
          cm.onStatus?.call('[Control] agent switched → $agent');
          break;

        case 'reset':
          cm.onStatus?.call('[Control] FORCE RESET triggered');

          // stop everything immediately
          await cm.stop();
          SleepService.wakeUp();

          cm.onStatus?.call('[Control] system reset complete');
          break;
      }
    });

    // Spawn HTTP server in separate isolate
    await Isolate.spawn<_ServerArgs>(
      _serverIsolateEntry,
      _ServerArgs(
        sendPort: receive.sendPort,
        ip: "0.0.0.0",
        port: port,
      ),
      errorsAreFatal: true,
    );

    cm.onStatus?.call(
      'ControlService: server isolate spawned on port $port',
    );
  }
}

/// Server isolate args
class _ServerArgs {
  final SendPort sendPort;
  final String ip;
  final int port;
  _ServerArgs({
    required this.sendPort,
    required this.ip,
    required this.port,
  });
}

/// ------------------------------------------------------
/// HTTP Server (runs in isolate)
/// ------------------------------------------------------
Future<void> _serverIsolateEntry(_ServerArgs args) async {
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler((Request request) async {
    // -------------------------------
    // POST /wake
    // -------------------------------
    if (request.method == 'POST' && request.url.path == 'wake') {
      args.sendPort.send(_CtrlMsg('wake'));
      return Response.ok('🌞 Wake triggered');
    }

    // -------------------------------
    // POST /sleep
    // -------------------------------
    if (request.method == 'POST' && request.url.path == 'sleep') {
      args.sendPort.send(_CtrlMsg('sleep'));
      return Response.ok('😴 Sleep triggered');
    }

    // -------------------------------
    // POST /agent { agent: "hotel" }
    // -------------------------------
    if (request.method == 'POST' && request.url.path == 'agent') {
      try {
        final body = await request.readAsString();
        final data = jsonDecode(body);
        final agent = (data['agent'] ?? 'default').toString();

        args.sendPort.send(_CtrlMsg('agent', agent));
        return Response.ok('🎭 Agent switched to $agent');

      } catch (e) {
        return Response.internalServerError(
          body: '❌ Error parsing agent payload: $e',
        );
      }
    }

    // -------------------------------
    // POST /reset — emergency hard reset
    // -------------------------------
    if (request.method == 'POST' && request.url.path == 'reset') {
      args.sendPort.send(_CtrlMsg('reset'));
      return Response.ok('🔄 Forced reset triggered');
    }

    return Response.notFound('Not found');
  });

  final server = await shelf_io.serve(
    handler,
    InternetAddress(args.ip),
    args.port,
  );

  print(
    '📡 ControlService listening on http://${server.address.host}:${server.port}',
  );
}
