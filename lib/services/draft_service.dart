import 'dart:convert';
import 'package:universal_io/io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DraftPost {
  final String id;
  final String mediaPath;
  final String? trackId;
  final String? caption;
  final DateTime createdAt;
  final String mediaType;

  DraftPost({
    required this.id,
    required this.mediaPath,
    this.trackId,
    this.caption,
    required this.createdAt,
    this.mediaType = 'video',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'mediaPath': mediaPath,
    'trackId': trackId,
    'caption': caption,
    'createdAt': createdAt.toIso8601String(),
    'mediaType': mediaType,
  };

  factory DraftPost.fromJson(Map<String, dynamic> json) => DraftPost(
    id: json['id'],
    mediaPath: json['mediaPath'],
    trackId: json['trackId'],
    caption: json['caption'],
    createdAt: DateTime.parse(json['createdAt']),
    mediaType: json['mediaType'] ?? 'video',
  );
}

class DraftService {
  static const String _draftsKey = 'necxa_drafts_v1';
  
  Future<List<DraftPost>> getDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(_draftsKey) ?? [];
    return data.map((e) => DraftPost.fromJson(jsonDecode(e))).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> saveDraft({
    required File mediaFile,
    String? trackId,
    String? caption,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final appDir = await getApplicationDocumentsDirectory();
    final draftsDir = Directory('${appDir.path}/drafts');
    if (!await draftsDir.exists()) await draftsDir.create(recursive: true);

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final extension = mediaFile.path.split('.').last;
    final newPath = '${draftsDir.path}/draft_$id.$extension';
    
    // Copy the file to our permanent drafts folder
    await mediaFile.copy(newPath);

    final draft = DraftPost(
      id: id,
      mediaPath: newPath,
      trackId: trackId,
      caption: caption,
      createdAt: DateTime.now(),
    );

    final drafts = await getDrafts();
    drafts.add(draft);
    
    await prefs.setStringList(
      _draftsKey, 
      drafts.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  Future<void> deleteDraft(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final drafts = await getDrafts();
    
    final draft = drafts.firstWhere((e) => e.id == id);
    final file = File(draft.mediaPath);
    if (await file.exists()) await file.delete();

    drafts.removeWhere((e) => e.id == id);
    await prefs.setStringList(
      _draftsKey, 
      drafts.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }
}
