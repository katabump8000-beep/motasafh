import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const Color wine = Color(0xFF8D1838);
const Color wineBright = Color(0xFFC02B50);
const Color ink = Color(0xFF050507);
const Color panel = Color(0xFF111116);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await InAppWebViewController.setWebContentsDebuggingEnabled(false);
  runApp(const AljesiApp());
}

class AljesiApp extends StatelessWidget {
  const AljesiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'الجيسي',
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: ink,
          colorScheme: const ColorScheme.dark(primary: wine, secondary: wineBright, surface: panel),
          useMaterial3: true,
          fontFamily: 'sans-serif',
        ),
        home: const BrowserHome(),
      );
}

class SavedSite {
  final String title;
  final String url;
  const SavedSite(this.title, this.url);
  Map<String, dynamic> toJson() => {'title': title, 'url': url};
  factory SavedSite.fromJson(Map<String, dynamic> j) => SavedSite(j['title'] ?? j['url'] ?? '', j['url'] ?? '');
}

class SavedValue {
  final String host;
  final String value;
  const SavedValue(this.host, this.value);
  Map<String, dynamic> toJson() => {'host': host, 'value': value};
  factory SavedValue.fromJson(Map<String, dynamic> j) => SavedValue(j['host'] ?? '', j['value'] ?? '');
}

class DownloadEntry {
  final String name;
  final String path;
  final int bytes;
  const DownloadEntry(this.name, this.path, this.bytes);
}

class BrowserHome extends StatefulWidget {
  const BrowserHome({super.key});
  @override
  State<BrowserHome> createState() => _BrowserHomeState();
}

class _BrowserHomeState extends State<BrowserHome> with TickerProviderStateMixin {
  InAppWebViewController? web;
  final address = TextEditingController();
  final focus = FocusNode();
  final stars = <SavedSite>[];
  final values = <SavedValue>[];
  final downloads = <DownloadEntry>[];
  final blockedHosts = <String>{'doubleclick.net', 'googlesyndication.com', 'adservice.google.com', 'adnxs.com', 'popads.net', 'taboola.com'};
  String currentUrl = 'https://www.google.com';
  String pageTitle = 'الجيسي';
  String? customFolder;
  bool adBlock = true;
  bool desktop = false;
  bool loading = false;
  bool onStart = true;
  bool testingSpeed = false;
  int progress = 0;
  int speedScore = 0;
  String? speedLabel;
  String? downloadStatus;
  int downloadReceived = 0;
  int downloadTotal = 0;
  late final AnimationController glow = AnimationController(vsync: this, duration: const Duration(seconds: 5))..repeat();

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  @override
  void dispose() {
    address.dispose();
    focus.dispose();
    glow.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getStringList('bookmarks') ?? [];
    final v = p.getStringList('saved_values') ?? [];
    if (!mounted) return;
    setState(() {
      stars.addAll(s.map((e) => SavedSite.fromJson(jsonDecode(e))));
      values.addAll(v.map((e) => SavedValue.fromJson(jsonDecode(e))));
      customFolder = p.getString('download_folder');
      adBlock = p.getBool('ad_block') ?? true;
      desktop = p.getBool('desktop') ?? false;
    });
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('bookmarks', stars.map((e) => jsonEncode(e.toJson())).toList());
    await p.setStringList('saved_values', values.map((e) => jsonEncode(e.toJson())).toList());
    await p.setBool('ad_block', adBlock);
    await p.setBool('desktop', desktop);
    if (customFolder != null) await p.setString('download_folder', customFolder!);
  }

  String _host(String url) => Uri.tryParse(url)?.host.toLowerCase() ?? '';

  String _normalize(String input) {
    final q = input.trim();
    if (q.isEmpty) return currentUrl;
    final uri = Uri.tryParse(q);
    if (uri != null && uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https')) return q;
    if (!q.contains(' ') && q.contains('.')) return 'https://$q';
    return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(q)}';
  }

  Future<void> _go([String? text]) async {
    final target = _normalize(text ?? address.text);
    focus.unfocus();
    if (mounted) setState(() => onStart = false);
    await web?.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
  }

  void _goHome() {
    focus.unfocus();
    setState(() { onStart = true; loading = false; progress = 0; address.clear(); });
  }

  Future<void> _onBack() async {
    if (onStart) { SystemNavigator.pop(); return; }
    if (await web?.canGoBack() ?? false) { web?.goBack(); } else { _goHome(); }
  }

  Future<void> _saveBookmark() async {
    if (currentUrl.isEmpty || currentUrl == 'about:blank') return;
    final exists = stars.any((e) => e.url == currentUrl);
    setState(() {
      if (exists) {
        stars.removeWhere((e) => e.url == currentUrl);
      } else {
        stars.insert(0, SavedSite(pageTitle.isEmpty ? currentUrl : pageTitle, currentUrl));
      }
    });
    await _persist();
    _toast(exists ? 'أزيل الموقع من المفضلة' : 'أضيف الموقع إلى المفضلة');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating, backgroundColor: const Color(0xFF292027), duration: const Duration(seconds: 2)));
  }

  Future<void> _showBookmarks() async {
    await showModalBottomSheet<void>(context: context, backgroundColor: panel, isScrollControlled: true, builder: (ctx) => SafeArea(child: SizedBox(height: MediaQuery.of(ctx).size.height * .72, child: Column(children: [
      const SizedBox(height: 12), Container(width: 42, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8))),
      const Padding(padding: EdgeInsets.all(18), child: Text('المواقع المحفوظة', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
      Expanded(child: stars.isEmpty ? const Center(child: Text('لم تحفظ أي موقع بعد', style: TextStyle(color: Colors.white54))) : ListView.builder(itemCount: stars.length, itemBuilder: (_, i) { final item = stars[i]; return ListTile(leading: const Icon(Icons.language, color: wineBright), title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white38, fontSize: 11)), onTap: () { Navigator.pop(ctx); _go(item.url); }, trailing: IconButton(icon: const Icon(Icons.close, color: Colors.white38), onPressed: () async { setState(() => stars.removeAt(i)); await _persist(); Navigator.pop(ctx); _showBookmarks(); })); })),
    ]))));
  }

  Future<void> _showDownloads() async {
    await showModalBottomSheet<void>(context: context, backgroundColor: panel, isScrollControlled: true, builder: (ctx) => SafeArea(child: SizedBox(height: MediaQuery.of(ctx).size.height * .72, child: Column(children: [
      const SizedBox(height: 14), const Text('التحميلات', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
      Padding(padding: const EdgeInsets.all(14), child: Row(children: [const Icon(Icons.folder_open, color: wineBright), const SizedBox(width: 8), Expanded(child: Text(customFolder ?? 'مجلد التطبيق الافتراضي', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 12))), TextButton(onPressed: () async { final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: 'اختر مجلد aljesi.511'); if (dir != null) { setState(() => customFolder = dir); await _persist(); if (ctx.mounted) Navigator.pop(ctx); _showDownloads(); } }, child: const Text('انتقل إلى'))])),
      const Divider(color: Colors.white10),
      Expanded(child: downloads.isEmpty ? const Center(child: Text('لا توجد ملفات محمّلة بعد', style: TextStyle(color: Colors.white54))) : ListView.builder(itemCount: downloads.length, itemBuilder: (_, i) { final d = downloads[i]; return ListTile(leading: const Icon(Icons.insert_drive_file_outlined, color: wineBright), title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(_formatBytes(d.bytes), style: const TextStyle(color: Colors.white38)), onTap: () => OpenFilex.open(d.path)); })),
    ]))));
  }

  String _formatBytes(int bytes) { if (bytes < 1024) return '$bytes B'; if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB'; return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'; }

  Future<void> _download(Uri uri, String? suggestedName) async {
    final name = (suggestedName?.trim().isNotEmpty ?? false) ? suggestedName!.split('/').last : (uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'download_${DateTime.now().millisecondsSinceEpoch}');
    setState(() { downloadStatus = 'جارٍ تحميل $name'; downloadReceived = 0; downloadTotal = 0; });
    _toast('مرحباً بك يا جيسي، بدأ تحميل الملف');
    try {
      final client = http.Client();
      final request = http.Request('GET', uri);
      final response = await client.send(request).timeout(const Duration(minutes: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) { client.close(); throw Exception('HTTP ${response.statusCode}'); }
      final builder = BytesBuilder(copy: false);
      final total = response.contentLength ?? 0;
      var received = 0;
      if (mounted) setState(() => downloadTotal = total);
      await for (final chunk in response.stream) {
        builder.add(chunk); received += chunk.length;
        if (mounted) setState(() => downloadReceived = received);
      }
      client.close();
      final fileBytes = builder.takeBytes();
      Directory dir;
      if (customFolder != null && await Directory(customFolder!).exists()) {
        dir = Directory(customFolder!);
      } else {
        dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
        await dir.create(recursive: true);
      }
      var path = '${dir.path}/$name';
      if (await File(path).exists()) path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$name';
      final file = File(path);
      await file.writeAsBytes(fileBytes, flush: true);
      if (!mounted) return;
      setState(() { downloads.insert(0, DownloadEntry(name, path, fileBytes.length)); downloadStatus = null; });
      _toast('اكتمل التحميل بنجاح');
      _showDownloads();
    } catch (e) {
      if (mounted) setState(() => downloadStatus = null);
      _toast('تعذر تحميل الملف. تحقق من الاتصال أو الرابط.');
    }
  }

  Future<void> _speedTest() async {
    if (testingSpeed) return;
    setState(() { testingSpeed = true; speedLabel = 'جارٍ قياس الاتصال'; });
    try {
      final sw = Stopwatch()..start();
      final res = await http.get(Uri.parse('https://speed.cloudflare.com/__down?bytes=1000000')).timeout(const Duration(seconds: 18));
      sw.stop();
      if (res.statusCode < 200 || res.statusCode >= 300) throw Exception('test failed');
      final mbps = (res.bodyBytes.length * 8) / (sw.elapsedMilliseconds / 1000) / 1000000;
      final score = (100 * (1 - exp(-mbps / 18))).round().clamp(1, 100);
      if (mounted) setState(() { speedScore = score; speedLabel = 'تقييم اتصالك'; testingSpeed = false; });
      _showSpeedResult();
    } catch (_) {
      if (mounted) setState(() { testingSpeed = false; speedLabel = 'تعذر الاختبار'; });
      _toast('لم نتمكن من اختبار الإنترنت حالياً');
    }
  }

  void _showSpeedResult() {
    final color = speedScore < 35 ? Colors.redAccent : speedScore < 70 ? Colors.orangeAccent : Colors.greenAccent;
    showDialog<void>(context: context, builder: (ctx) => Dialog(backgroundColor: panel, child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('قوة الإنترنت', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), const SizedBox(height: 22), SizedBox(width: 150, height: 150, child: Stack(alignment: Alignment.center, children: [SizedBox.expand(child: CircularProgressIndicator(value: speedScore / 100, strokeWidth: 12, backgroundColor: Colors.white10, color: color, strokeCap: StrokeCap.round)), Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text('$speedScore', style: TextStyle(fontSize: 43, fontWeight: FontWeight.bold, color: color)), const Text('من 100', style: TextStyle(color: Colors.white54))])])), const SizedBox(height: 18), Text(speedScore < 35 ? 'ضعيف' : speedScore < 70 ? 'متوسط' : 'قوي', style: TextStyle(color: color, fontSize: 17, fontWeight: FontWeight.bold)), const SizedBox(height: 18), FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('حسناً'))]))));
  }

  Future<void> _toggleDesktop() async {
    setState(() => desktop = !desktop);
    await _persist();
    await web?.setSettings(settings: InAppWebViewSettings(userAgent: desktop ? 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' : null));
    await web?.reload();
  }

  Future<void> _translate() async {
    final target = 'https://translate.google.com/translate?sl=auto&tl=ar&u=${Uri.encodeComponent(currentUrl)}';
    _go(target);
  }

  Future<void> _menu() async {
    await showModalBottomSheet<void>(context: context, backgroundColor: panel, builder: (ctx) => SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 18, 16, 22), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [const Icon(Icons.more_horiz, color: wineBright, size: 25), const SizedBox(width: 8), const Text('الجيسي', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const Spacer(), const Text('ALJESI', style: TextStyle(color: Colors.white30, letterSpacing: 2))]), const SizedBox(height: 16),
      _menuRow(Icons.download_outlined, 'التحميلات', () { Navigator.pop(ctx); _showDownloads(); }),
      _menuRow(Icons.desktop_windows_outlined, desktop ? 'إيقاف وضع سطح المكتب' : 'وضع سطح المكتب', () { Navigator.pop(ctx); _toggleDesktop(); }, trailing: Switch(value: desktop, onChanged: (_) { Navigator.pop(ctx); _toggleDesktop(); }, activeColor: wineBright)),
      _menuRow(Icons.translate, 'ترجمة الصفحة', () { Navigator.pop(ctx); _translate(); }),
      _menuRow(Icons.shield_outlined, 'مانع الإعلانات', () { setState(() => adBlock = !adBlock); _persist(); Navigator.pop(ctx); _toast(adBlock ? 'تم تشغيل مانع الإعلانات' : 'تم إيقاف مانع الإعلانات'); }, trailing: Switch(value: adBlock, onChanged: (v) { setState(() => adBlock = v); _persist(); Navigator.pop(ctx); }, activeColor: wineBright)),
      _menuRow(Icons.bookmark_outline, 'المواقع المحفوظة', () { Navigator.pop(ctx); _showBookmarks(); }),
      _menuRow(Icons.speed, 'اختبار سرعة الإنترنت', () { Navigator.pop(ctx); _speedTest(); }),
    ]))));
  }

  Widget _menuRow(IconData icon, String title, VoidCallback action, {Widget? trailing}) => ListTile(contentPadding: EdgeInsets.zero, leading: Icon(icon, color: wineBright), title: Text(title), trailing: trailing ?? const Icon(Icons.chevron_left, color: Colors.white30), onTap: action);

  Future<void> _injectSavedFields() async {
    final hostValues = values.where((v) => v.host == _host(currentUrl)).map((v) => v.value).toList();
    final encoded = jsonEncode(hostValues);
    final js = '''(function(){try{if(window.__aljesiInstalled)return;window.__aljesiInstalled=true;const saved=$encoded;let timer=null;let active=null;function remove(){let x=document.getElementById('aljesi-save');if(x)x.remove();let y=document.getElementById('aljesi-fill');if(y)y.remove();}function pill(id,label,top,left,fn){let b=document.createElement('button');b.id=id;b.textContent=label;b.style.cssText='position:fixed;z-index:2147483647;top:'+top+'px;left:'+left+'px;background:#8d1838;color:white;border:1px solid #d34a6b;border-radius:18px;padding:9px 15px;font:14px sans-serif;box-shadow:0 5px 22px #0009';b.addEventListener('click',function(e){e.preventDefault();e.stopPropagation();fn();remove()});document.body.appendChild(b)}document.addEventListener('pointerdown',function(e){let el=e.target;if(!el||!['INPUT','TEXTAREA'].includes(el.tagName))return;active=el;timer=setTimeout(function(){remove();pill('aljesi-save','احفظ',Math.max(8,e.clientY-55),Math.max(8,e.clientX-25),function(){window.flutter_inappwebview.callHandler('aljesiSaveField',active.value||'')})},650)});document.addEventListener('pointerup',function(){clearTimeout(timer)});document.addEventListener('focusin',function(e){let el=e.target;if(!el||!['INPUT','TEXTAREA'].includes(el.tagName)||!saved.length)return;remove();pill('aljesi-fill','استخدم محفوظاً',Math.max(8,el.getBoundingClientRect().top-48),Math.max(8,el.getBoundingClientRect().left),function(){el.value=saved[saved.length-1];el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}))})});document.addEventListener('focusout',function(){setTimeout(remove,1200)})}catch(e){}})();''';
    await web?.evaluateJavascript(source: js);
  }

  Future<void> _saveField(String value) async {
    if (value.trim().isEmpty) { _toast('لا يوجد نص لحفظه'); return; }
    final host = _host(currentUrl);
    final exists = values.any((v) => v.host == host && v.value == value);
    if (!exists) values.add(SavedValue(host, value));
    await _persist();
    _toast('تم حفظ النص لهذا الموقع');
    await _injectSavedFields();
  }

  @override
  Widget build(BuildContext context) {
    final isBookmarked = stars.any((e) => e.url == currentUrl);
    return PopScope(canPop: false, onPopInvokedWithResult: (didPop, _) { if (!didPop) _onBack(); }, child: Scaffold(
      body: Stack(children: [
        const Positioned.fill(child: Starfield()),
        SafeArea(child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 8), child: Row(children: [
            Expanded(child: Container(height: 48, decoration: BoxDecoration(color: const Color(0xE615151B), borderRadius: BorderRadius.circular(17), border: Border.all(color: wine.withOpacity(.65))), child: Row(children: [const SizedBox(width: 12), const Icon(Icons.search, color: wineBright, size: 21), const SizedBox(width: 7), Expanded(child: TextField(controller: address, focusNode: focus, textInputAction: TextInputAction.go, keyboardType: TextInputType.url, style: const TextStyle(fontSize: 14), decoration: const InputDecoration(hintText: 'ابحث أو اكتب عنوان الموقع', hintStyle: TextStyle(color: Colors.white38, fontSize: 13), border: InputBorder.none, isDense: true), onSubmitted: _go)), if (loading) const Padding(padding: EdgeInsets.only(right: 12), child: SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: wineBright))) else IconButton(onPressed: () => address.clear(), icon: const Icon(Icons.close, size: 17, color: Colors.white38))]))),
            const SizedBox(width: 8), _roundButton(Icons.more_vert, _menu), const SizedBox(width: 7), _roundButton(isBookmarked ? Icons.star : Icons.star_border, _saveBookmark, color: isBookmarked ? wineBright : Colors.white),
          ])),
          if (progress > 0 && progress < 100) LinearProgressIndicator(value: progress / 100, minHeight: 2, backgroundColor: Colors.transparent, color: wineBright),
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(15), child: Container(margin: const EdgeInsets.fromLTRB(7, 0, 7, 5), decoration: BoxDecoration(color: onStart ? Colors.transparent : const Color(0xFF08080C), border: Border.all(color: wine.withOpacity(.22)), borderRadius: BorderRadius.circular(15)), child: Stack(children: [Offstage(offstage: onStart, child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri('about:blank')),
            initialSettings: InAppWebViewSettings(javaScriptEnabled: true, domStorageEnabled: true, databaseEnabled: true, supportZoom: true, transparentBackground: true, useShouldOverrideUrlLoading: true, allowsBackForwardNavigationGestures: true, userAgent: desktop ? 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' : null),
            onWebViewCreated: (controller) { web = controller; controller.addJavaScriptHandler(handlerName: 'aljesiSaveField', callback: (args) { if (args.isNotEmpty) _saveField(args.first.toString()); return true; }); },
            onLoadStart: (controller, url) { if (url == null || url.toString() == 'about:blank') return; setState(() { loading = true; currentUrl = url.toString(); address.text = currentUrl; }); },
            onLoadStop: (controller, url) async { if (url == null || url.toString() == 'about:blank') return; setState(() { loading = false; progress = 100; if (url != null) { currentUrl = url.toString(); address.text = currentUrl; } }); pageTitle = await controller.getTitle() ?? currentUrl; await _injectSavedFields(); Future.delayed(const Duration(milliseconds: 700), () { if (mounted) setState(() => progress = 0); }); },
            onProgressChanged: (_, p) { if (onStart) return; setState(() { progress = p; loading = p < 100; }); },
            onTitleChanged: (_, title) { if (title != null) setState(() => pageTitle = title); },
            shouldOverrideUrlLoading: (controller, action) async { final url = action.request.url; if (url == null) return NavigationActionPolicy.ALLOW; if (adBlock && blockedHosts.any((h) => url.host.toLowerCase() == h || url.host.toLowerCase().endsWith('.$h'))) return NavigationActionPolicy.CANCEL; if (!['http', 'https', 'file', 'about', 'data'].contains(url.scheme)) { if (await canLaunchUrl(Uri.parse(url.toString()))) await launchUrl(Uri.parse(url.toString()), mode: LaunchMode.externalApplication); return NavigationActionPolicy.CANCEL; } return NavigationActionPolicy.ALLOW; },
            onDownloadStartRequest: (controller, request) { final uri = Uri.tryParse(request.url.toString()); if (uri != null) _download(uri, request.suggestedFilename); },
          )), if (onStart) _startPage()])))),
          if (downloadStatus != null) Container(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9), decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(12), border: Border.all(color: wine.withOpacity(.5))), child: Column(children: [Row(children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: wineBright)), const SizedBox(width: 10), Expanded(child: Text(downloadStatus!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))), Text(downloadTotal > 0 ? '${(downloadReceived * 100 / downloadTotal).clamp(0, 100).round()}%' : '...', style: const TextStyle(color: wineBright, fontSize: 11))]), const SizedBox(height: 8), ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(value: downloadTotal > 0 ? (downloadReceived / downloadTotal).clamp(0, 1) : null, minHeight: 4, backgroundColor: Colors.white10, color: wineBright))])),
          Container(height: 60, margin: const EdgeInsets.fromLTRB(9, 2, 9, 8), padding: const EdgeInsets.symmetric(horizontal: 12), decoration: BoxDecoration(color: const Color(0xE6111116), borderRadius: BorderRadius.circular(19), border: Border.all(color: wine.withOpacity(.35))), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _navButton(Icons.arrow_back_ios_new, _onBack),
            _navButton(Icons.arrow_forward_ios, () async { if (await web?.canGoForward() ?? false) web?.goForward(); }),
            _navButton(Icons.home_outlined, _goHome, accent: true),
            _navButton(Icons.refresh, () { if (!onStart) web?.reload(); }),
            _navButton(Icons.tab, _showTabs),
          ])),
        ])),
      ]),
    ));
  }

  Widget _startPage() {
    final quick = <SavedSite>[const SavedSite('Google', 'https://www.google.com'), const SavedSite('YouTube', 'https://www.youtube.com'), const SavedSite('ويكيبيديا', 'https://ar.wikipedia.org'), ...stars.take(6)];
    return Positioned.fill(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('ALJESI', style: TextStyle(fontSize: 15, letterSpacing: 7, color: Colors.white38)),
      const SizedBox(height: 6),
      const Text('الجيسي', style: TextStyle(fontSize: 46, fontWeight: FontWeight.bold, color: Colors.white)),
      const SizedBox(height: 8),
      const Text('ابحث أو اكتب عنوان الموقع في الأعلى', style: TextStyle(color: Colors.white54, fontSize: 13)),
      const SizedBox(height: 26),
      Wrap(alignment: WrapAlignment.center, spacing: 9, runSpacing: 9, children: [for (final q in quick) ActionChip(avatar: const Icon(Icons.language, size: 17, color: wineBright), label: Text(q.title.length > 18 ? '${q.title.substring(0, 18)}…' : q.title), backgroundColor: const Color(0xCC15151B), side: BorderSide(color: wine.withOpacity(.6)), onPressed: () => _go(q.url))]),
    ]))));
  }

  Widget _roundButton(IconData icon, VoidCallback action, {Color color = Colors.white}) => Material(color: const Color(0xE615151B), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15), side: BorderSide(color: wine.withOpacity(.55))), child: InkWell(borderRadius: BorderRadius.circular(15), onTap: action, child: SizedBox(width: 45, height: 48, child: Icon(icon, color: color, size: 22))));
  Widget _navButton(IconData icon, VoidCallback action, {bool accent = false}) => IconButton(onPressed: action, icon: Icon(icon, color: accent ? wineBright : Colors.white70, size: 23), splashRadius: 23);
  Future<void> _showTabs() async { final url = currentUrl; await showModalBottomSheet<void>(context: context, backgroundColor: panel, builder: (ctx) => SafeArea(child: Padding(padding: const EdgeInsets.all(22), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.tab, color: wineBright, size: 30), const SizedBox(height: 10), const Text('علامة التبويب الحالية', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)), const SizedBox(height: 8), Text(pageTitle, maxLines: 1, overflow: TextOverflow.ellipsis), Text(url, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white38, fontSize: 11)), const SizedBox(height: 12), FilledButton.icon(onPressed: () { Navigator.pop(ctx); _goHome(); }, icon: const Icon(Icons.add), label: const Text('صفحة جديدة'))])))); }
}

class Starfield extends StatefulWidget { const Starfield({super.key}); @override State<Starfield> createState() => _StarfieldState(); }
class _StarfieldState extends State<Starfield> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(seconds: 18))..repeat();
  final stars = List.generate(95, (i) => _Star(Random(i * 17 + 4).nextDouble(), Random(i * 31 + 9).nextDouble(), Random(i * 13 + 2).nextDouble() * 1.5 + .3, Random(i * 23 + 5).nextDouble()));
  @override void dispose() { c.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => RepaintBoundary(child: AnimatedBuilder(animation: c, builder: (_, __) => CustomPaint(painter: StarPainter(stars, c.value), child: const SizedBox.expand())));
}
class _Star { final double x,y,r,phase; _Star(this.x,this.y,this.r,this.phase); }
class StarPainter extends CustomPainter {
  final List<_Star> stars; final double t; StarPainter(this.stars,this.t);
  @override void paint(Canvas canvas, Size size) {
    final bg = Paint()..shader = const RadialGradient(colors: [Color(0xFF1B0C17), ink], radius: 1.1).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);
    for (final s in stars) {
      final pulse = (sin((t * 2 * pi) + s.phase * 2 * pi) + 1) / 2;
      canvas.drawCircle(Offset(s.x * size.width, s.y * size.height), s.r, Paint()..color = Colors.white.withOpacity(.15 + pulse * .6));
    }
    // 4 shooting stars, each streaks across the screen once per cycle at different times/places
    const starts = [0.00, 0.27, 0.51, 0.76];
    const xs = [0.05, 0.45, 0.20, 0.60];
    const ys = [0.05, 0.12, 0.38, 0.25];
    for (var k = 0; k < 4; k++) {
      final local = (t - starts[k]) % 1.0;
      if (local > 0.12) continue;
      final u = local / 0.12;
      final dir = Offset(0.85, 0.53);
      final head = Offset(xs[k] * size.width, ys[k] * size.height) + dir * (u * size.width * 0.75);
      final tail = head - dir * 130;
      final fade = sin(u * pi).clamp(0.0, 1.0);
      final paint = Paint()
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(colors: [Colors.white.withOpacity(0), wineBright.withOpacity(.85 * fade), Colors.white.withOpacity(fade)]).createShader(Rect.fromPoints(tail, head));
      canvas.drawLine(tail, head, paint);
      canvas.drawCircle(head, 2.4, Paint()..color = Colors.white.withOpacity(fade));
    }
  }
  @override bool shouldRepaint(covariant StarPainter old) => old.t != t;
}
