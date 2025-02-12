import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:voicevox_flutter/voicevox_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class NativeVoiceService {
  late Isolate isolate;
  late SendPort sendPort;
  Future<void> initialize() async {
    final receivePort = ReceivePort();
    final rootToken = RootIsolateToken.instance!;
    isolate =
        await Isolate.spawn<(SendPort, RootIsolateToken)>((message) async {
      BackgroundIsolateBinaryMessenger.ensureInitialized(message.$2);

      final receivePort = ReceivePort();
      message.$1.send(receivePort.sendPort);

      receivePort.listen((message) async {
        message = message as Map<String, dynamic>;
        switch (message['method']) {
          case 'initialize':
            await _initialize(
              message['openJdkDictPath'] as String,
              message['modelPathList'] as List<String>,
            );
            (message['sendPort'] as SendPort).send(null);
          case 'audioQuery':
            (message['sendPort'] as SendPort).send(
              _audioQuery(message['text'] as String, message['styleId'] as int),
            );
          case 'synthesis':
            (message['sendPort'] as SendPort).send(
              await _synthesis(
                  message['query'] as String, message['styleId'] as int),
            );

          case 'tts':
            (message['sendPort'] as SendPort).send(
              await _tts(message['query'] as String, message['styleId'] as int),
            );
        }
      });
    }, (receivePort.sendPort, rootToken));
    sendPort = await receivePort.first as SendPort;

    final r = ReceivePort();
    sendPort.send({
      'method': 'initialize',
      'openJdkDictPath': await _setOpenJdkDict(),
      'modelPathList': await _setModel(),
      'sendPort': r.sendPort,
    });
    await r.first;
  }

  /// AudioQuery を生成する
  Future<String> audioQuery(String text, int styleId) async {
    final receivePort = ReceivePort();
    sendPort.send({
      'method': 'audioQuery',
      'text': text,
      'styleId': styleId,
      'sendPort': receivePort.sendPort,
    });
    return (await receivePort.first) as String;
  }

  /// AudioQueryから合成を実行する
  Future<String> synthesis(String query, int styleId) async {
    final receivePort = ReceivePort();
    sendPort.send({
      'method': 'synthesis',
      'query': query,
      'styleId': styleId,
      'sendPort': receivePort.sendPort,
    });
    return (await receivePort.first) as String;
  }

  /// テキスト音声合成を実行する
  Future<String> tts(String query, int styleId) {
    final receivePort = ReceivePort();
    sendPort.send({
      'method': 'tts',
      'query': query,
      'styleId': styleId,
      'sendPort': receivePort.sendPort,
    });
    return receivePort.first as Future<String>;
  }

  void dispose() {
    isolate.kill();
  }
}

Future<void> _initialize(
    String openJdkDictPath, List<String> modelPathList) async {
  await VoicevoxFlutter.instance.initialize(
    openJdkDictPath: openJdkDictPath,
    cpuNumThreads: 4,
  );
  modelPathList.forEach(VoicevoxFlutter.instance.loadVoiceModel);
}

String _audioQuery(String text, int styleId) {
  return VoicevoxFlutter.instance.audioQuery(text, styleId: styleId);
}

Future<String> _synthesis(String query, int styleId) async {
  final wavFile = File(
      '${(await getApplicationDocumentsDirectory()).path}/${query.hashCode}.wav');
  final watch = Stopwatch()..start();
  VoicevoxFlutter.instance.synthesis(
    query,
    styleId: styleId,
    outputPath: wavFile.path,
  );
  watch.stop();
  // 合成にかかった時間を表示する
  debugPrint('${watch.elapsedMilliseconds}ms');
  return wavFile.path;
}

/// テキスト音声合成を実行する
Future<String> _tts(String query, int styleId) async {
  final wavFile =
      File('${(await getApplicationDocumentsDirectory()).path}/voice.wav');
  final watch = Stopwatch()..start();
  VoicevoxFlutter.instance.tts(
    query,
    styleId: styleId,
    outputPath: wavFile.path,
  );
  watch.stop();
  // 合成にかかった時間を表示する
  debugPrint('${watch.elapsedMilliseconds}ms');
  return wavFile.path;
}

/// アセットからアプリケーションディレクトリにファイルをコピーする
Future<void> _copyFile(
    String filename, String assetsDir, String targetDirPath) async {
  final data = await rootBundle.load('$assetsDir/$filename');
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  File('$targetDirPath/$filename').writeAsBytesSync(bytes);
}

/// アセットからアプリケーションディレクトリに`open_jtalk_dict`をコピーする
Future<String> _setOpenJdkDict() async {
  final openJdkDictDir = Directory(
      '${(await getApplicationSupportDirectory()).path}/open_jtalk_dic_utf_8-1.11');

  if (!openJdkDictDir.existsSync()) {
    openJdkDictDir.createSync();
    const openJdkDicAssetDir = 'assets/open_jtalk_dic_utf_8-1.11';

    final manifestContent = await rootBundle.loadString('AssetManifest.json');
    final manifestMap = json.decode(manifestContent) as Map<String, dynamic>;
    // open_jtalk_dic_utf_8-1.11ディレクトリ以下のファイルをコピーする
    manifestMap.keys
        .where((e) => e.contains(openJdkDicAssetDir))
        .map(p.basename)
        .forEach((name) async {
      await _copyFile(name, openJdkDicAssetDir, openJdkDictDir.path);
    });
  }
  return openJdkDictDir.path;
}

/// アセットからアプリケーションディレクトリに`model`をコピーする
Future<List<String>> _setModel() async {
  final modelDir =
      Directory('${(await getApplicationSupportDirectory()).path}/model');
  final modelPathList = <String>[];
  modelDir.createSync();
  const modelAssetDir = 'assets/model';

  final manifestContent = await rootBundle.loadString('AssetManifest.json');
  final manifestMap = json.decode(manifestContent) as Map<String, dynamic>;

  // modelディレクトリ以下のファイルをコピーする
  final vvmFileList = manifestMap.keys
      .where((e) => e.contains(modelAssetDir))
      .map(p.basename)
      .where((e) => p.extension(e) == '.vvm');
  for (final name in vvmFileList) {
    await _copyFile(name, modelAssetDir, modelDir.path);
    modelPathList.add(p.join(modelDir.path, name));
  }

  return modelPathList;
}
