import 'dart:async';
import 'dart:math';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:clipboard_listener/clipboard_listener.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:icofont_flutter/icofont_flutter.dart';

import 'package:arujisho/splash_screen.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  static const isRelease = true;
  const MyApp({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: 'ある辞書',
        theme: isRelease
            ? ThemeData(
                primarySwatch: Colors.blue,
              )
            : ThemeData(
                colorScheme: ColorScheme.fromSwatch().copyWith(
                  primary: Colors.pink[300],
                  secondary: Colors.pinkAccent[100],
                ),
              ),
        initialRoute: '/splash',
        routes: {
          '/': (context) => const MyHomePage(),
          '/splash': (context) => const SplashScreen(),
        });
  }
}

typedef RequestFn<T> = Future<List<T>> Function(int nextIndex);
typedef ItemBuilder<T> = Widget Function(
    BuildContext context, T item, int index);

class InfiniteList<T> extends StatefulWidget {
  final RequestFn<T> onRequest;
  final ItemBuilder<T> itemBuilder;

  const InfiniteList(
      {Key? key, required this.onRequest, required this.itemBuilder})
      : super(key: key);

  @override
  _InfiniteListState<T> createState() => _InfiniteListState<T>();
}

class _InfiniteListState<T> extends State<InfiniteList<T>> {
  List<T> items = [];
  bool end = false;

  _getMoreItems() async {
    final moreItems = await widget.onRequest(items.length);
    if (!mounted) return;

    if (moreItems.isEmpty) {
      setState(() => end = true);
      return;
    }
    setState(() => items = [...items, ...moreItems]);
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemBuilder: (context, index) {
        if (index < items.length) {
          return widget.itemBuilder(context, items[index], index);
        } else if (index == items.length && end) {
          return const Center(child: Text('以上です'));
        } else {
          _getMoreItems();
          return const SizedBox(
            child: Center(
                child: Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator())),
          );
        }
      },
      itemCount: items.length + 1,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final TextEditingController _controller = TextEditingController();
  final StreamController _streamController = StreamController();
  final List<String> _history = [''];
  int _searchMode = 0;
  Timer? _debounce;
  static Database? _db;
  Future<Database> get database async {
    if (_db != null) return _db!;

    var databasesPath = await getDatabasesPath();
    var path = join(databasesPath, "arujisho.db");

    _db = await openDatabase(path, readOnly: true);
    return _db!;
  }

  static JavascriptRuntime? _fjs;
  Future<JavascriptRuntime> get flutterJs async {
    if (_fjs != null) return _fjs!;
    JavascriptRuntime t = getJavascriptRuntime();
    String cjconvert = await rootBundle.loadString("js/cjconvert.js");
    t.evaluate(cjconvert);
    _fjs = t;
    return _fjs!;
  }

  _search(int mode) async {
    if (_controller.text.isEmpty) {
      _streamController.add(null);
      return;
    }
    _searchMode = mode;
    JavascriptRuntime t = await flutterJs;
    String s = _controller.text;
    s = s.replaceAll("\\pc", "\\p{Han}");
    s = s.replaceAll("\\ph", "\\p{Hiragana}");
    s = s.replaceAll("\\pk", "\\p{Katakana}");
    s = t.evaluate('cj_convert(${json.encode(s)})').stringResult;
    _streamController.add(s);
  }

  void _hastuon(Map item) async {
    final player = AudioPlayer();
    Map<String, String> burpHeader = {
      "Sec-Ch-Ua":
          "\"Chromium\";v=\"104\", \" Not A;Brand\";v=\"99\", \"Google Chrome\";v=\"104\"",
      "Dnt": "1",
      "Sec-Ch-Ua-Mobile": "?0",
      "User-Agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.0.0 Safari/537.36",
      "Sec-Ch-Ua-Platform": "\"Windows\"",
      "Content-Type": "application/x-www-form-urlencoded",
      "Accept": "*/*",
      "Origin": "https://www.japanesepod101.com",
      "Sec-Fetch-Site": "none",
      "Sec-Fetch-Mode": "cors",
      "Sec-Fetch-Dest": "empty",
      "Accept-Encoding": "gzip, deflate",
      "Accept-Language":
          "en-US,en;q=0.9,zh-TW;q=0.8,zh-CN;q=0.7,zh;q=0.6,ja;q=0.5",
      "Connection": "close"
    };
    String? url;
    try {
      var resp = await http.post(
          Uri.parse(
              'https://www.japanesepod101.com/learningcenter/reference/dictionary_post'),
          headers: burpHeader,
          body: {
            "post": "dictionary_reference",
            "match_type": "exact",
            "search_query": item['word'],
            "vulgar": "true"
          });
      var dom = parse(resp.body);
      for (var row in dom.getElementsByClassName('dc-result-row')) {
        try {
          var audio = row.getElementsByTagName('audio')[0];
          var roma =
              row.getElementsByClassName('dc-vocab_romanization')[0].text;
          if (item['romaji'] == roma) {
            url = audio.getElementsByTagName('source')[0].attributes['src'];
            break;
          }
        } catch (_) {}
      }
    } catch (_) {}
    if(url != null && url.isNotEmpty) {
      try {
        await player.setUrl(url, headers: burpHeader);
        await player.play();
      } catch (_) {}
    }
  }

  _cpListener() async {
    String cp = (await Clipboard.getData('text/plain'))!.text ?? '';
    if (cp == _controller.text) {
      return;
    }
    _history.add(_controller.text);
    _controller.value = TextEditingValue(
        text: cp,
        selection: TextSelection.fromPosition(TextPosition(offset: cp.length)));
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (_debounce?.isActive ?? false) return;
      _debounce = Timer(const Duration(milliseconds: 300), () {
        _search(0);
      });
      setState(() {});
    });
    ClipboardListener.addListener(_cpListener);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _fjs?.dispose();
    ClipboardListener.removeListener(_cpListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
        onWillPop: () async {
          if (_history.isEmpty) return true;
          String temp = _history.last;
          _history.removeLast();
          _controller.value = TextEditingValue(
              text: temp,
              selection: TextSelection.fromPosition(
                  TextPosition(offset: temp.length)));
          return false;
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text("ある辞書", style: TextStyle(fontSize: 20)),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(48.0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.only(left: 12.0, bottom: 8.0),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24.0),
                      ),
                      child: TextFormField(
                        controller: _controller,
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          hintText: "調べたい言葉をご入力してください",
                          contentPadding:
                              const EdgeInsets.fromLTRB(20, 12, 12, 12),
                          border: InputBorder.none,
                          suffixIcon: _controller.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear, size: 20),
                                  onPressed: () {
                                    setState(() => _controller.clear());
                                  },
                                ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    icon: const Icon(
                      BootstrapIcons.sort_down_alt,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      _search(1);
                    },
                  )
                ],
              ),
            ),
          ),
          body: Container(
              margin: const EdgeInsets.all(8.0),
              child: StreamBuilder(
                  stream: _streamController.stream,
                  builder: (BuildContext ctx, AsyncSnapshot snapshot) {
                    if (snapshot.data == null) {
                      return const Center(
                        child: Text("ご参考になりましたら幸いです"),
                      );
                    }
                    Future<List<Map>> queryAuto(int nextIndex) async {
                      const pageSize = 35;
                      if (nextIndex % pageSize != 0) {
                        return [];
                      }
                      Database db = await database;
                      String searchField = 'word';
                      String method = "MATCH";
                      List<Map> result = <Map>[];
                      if (snapshot.data
                          .toLowerCase()
                          .contains(RegExp(r'^[a-z]+$'))) {
                        searchField = 'romaji';
                      } else if (snapshot.data.contains(RegExp(r'^[ぁ-ゖー]+$'))) {
                        searchField = 'yomikata';
                      } else if (snapshot.data
                          .contains(RegExp(r'[\.\+\[\]\*\^\$\?]'))) {
                        method = 'REGEXP';
                      } else if (snapshot.data.contains(RegExp(r'[_%]'))) {
                        method = 'LIKE';
                      }
                      try {
                        if (method == "MATCH") {
                          result = List.of(await db.rawQuery(
                            'SELECT tt.word,tt.yomikata,tt.pitchData,'
                            'tt.origForm,tt.freqRank,tt.romaji,imis.imi,imis.orig '
                            'FROM (imis JOIN (SELECT * FROM jpdc '
                            'WHERE $searchField MATCH "${snapshot.data}*" OR r$searchField '
                            'MATCH "${String.fromCharCodes(snapshot.data.runes.toList().reversed)}*" '
                            'ORDER BY _rowid_ LIMIT $nextIndex, $pageSize'
                            ') AS tt ON tt.idex=imis._rowid_)',
                          ));
                        } else {
                          result = List.of(await db.rawQuery(
                            'SELECT tt.word,tt.yomikata,tt.pitchData,'
                            'tt.origForm,tt.freqRank,tt.romaji,imis.imi,imis.orig '
                            'FROM (imis JOIN (SELECT * FROM jpdc '
                            'WHERE word $method "${snapshot.data}" '
                            'OR yomikata $method "${snapshot.data}" '
                            'OR romaji $method "${snapshot.data}" '
                            'ORDER BY _rowid_ LIMIT $nextIndex, $pageSize'
                            ') AS tt ON tt.idex=imis._rowid_)',
                          ));
                        }
                        result = result.map((qRow) {
                          Map map = {};
                          qRow.forEach((key, value) => map[key] = value);
                          return map;
                        }).toList();
                        int balancedWeight(Map item, int bLen) {
                          return (item['freqRank'] *
                                  (item[searchField]
                                              .startsWith(snapshot.data) &&
                                          _searchMode == 0
                                      ? 100
                                      : 500) *
                                  pow(item['romaji'].length / bLen,
                                      _searchMode == 0 ? 2 : 0))
                              .round();
                        }

                        int bLen = 1 << 31;
                        for (var w in result) {
                          if (w['word'].length < bLen) {
                            bLen = w['word'].length;
                          }
                        }
                        result.sort((a, b) => balancedWeight(a, bLen)
                            .compareTo(balancedWeight(b, bLen)));
                        return result;
                      } catch (e) {
                        return nextIndex == 0
                            ? [
                                {
                                  'word': 'EXCEPTION',
                                  'yomikata': '以下の説明をご覧ください',
                                  'pitchData': '',
                                  'freqRank': -1,
                                  'romaji': '',
                                  'orig': 'EXCEPTION',
                                  'origForm': '',
                                  'imi': jsonEncode({
                                    'ヘルプ': [
                                      "LIKE 検索:\n"
                                          "    _  任意の1文字\n"
                                          "    %  任意の0文字以上の文字列\n"
                                          "\n"
                                          "REGEX 検索:\n"
                                          "    .  任意の1文字\n"
                                          "    .*  任意の0文字以上の文字列\n"
                                          "    .+  任意の1文字以上の文字列\n"
                                          "    \\pc	任意漢字\n"
                                          "    \\ph	任意平仮名\n"
                                          "    \\pk	任意片仮名\n"
                                          "    []	候補。[]で括られた中の文字は、その中のどれか１つに合致する訳です\n"
                                          "\n"
                                          "例えば：\n"
                                          " \"ta%_eru\" は、食べる、訪ねる、立ち上げる 等\n"
                                          " \"[\\pc][\\pc\\ph]+る\" は、出来る、聞こえる、取り入れる 等\n"
                                    ],
                                    'Debug': [e.toString()],
                                  }),
                                  'expanded': true
                                }
                              ]
                            : [];
                      }
                    }

                    return InfiniteList<Map>(
                      onRequest: queryAuto,
                      itemBuilder: (context, item, index) {
                        Map<String, dynamic> imi = jsonDecode(item['imi']);
                        final String pitchData = item['pitchData'] != ''
                            ? jsonDecode(item['pitchData'])
                                .map((x) =>
                                    x <= 20 ? '⓪①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳'[x] : '?')
                                .toList()
                                .join()
                            : '';
                        final word = item['origForm'] == ''
                            ? item['word']
                            : item['origForm'];

                        return ListTileTheme(
                            dense: true,
                            child: ExpansionTile(
                                initiallyExpanded:
                                    item.containsKey('expanded') &&
                                        item['expanded'],
                                title: Text(word == item['orig']
                                    ? word
                                    : '$word →〔${item['orig']}〕'),
                                trailing: item.containsKey('expanded') &&
                                        item['freqRank'] != -1 &&
                                        item['expanded']
                                    ? Container(
                                        padding: const EdgeInsets.all(0.0),
                                        width:
                                            30.0, // you can adjust the width as you need
                                        child: IconButton(
                                            icon: const Icon(
                                                IcoFontIcons.soundWaveAlt),
                                            onPressed: () => _hastuon(item)))
                                    : Text(item['freqRank'].toString()),
                                subtitle: Text("${item['yomikata']} "
                                    "$pitchData"),
                                children: imi.keys
                                    .map<List<Widget>>((s) =>
                                        <Widget>[
                                          Container(
                                              decoration: BoxDecoration(
                                                  color: MyApp.isRelease
                                                      ? Colors.red[600]
                                                      : Colors.blue[400],
                                                  borderRadius:
                                                      const BorderRadius.all(
                                                          Radius.circular(20))),
                                              child: Padding(
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                          5, 0, 5, 0),
                                                  child: Text(
                                                    s,
                                                    style: const TextStyle(
                                                        color: Colors.white),
                                                  ))),
                                        ] +
                                        List<List<Widget>>.from(
                                            imi[s].map((simi) => <Widget>[
                                                  ListTile(
                                                      title: SelectableText(
                                                          simi,
                                                          toolbarOptions:
                                                              const ToolbarOptions(
                                                                  copy: true,
                                                                  selectAll:
                                                                      false))),
                                                  const Divider(
                                                      color: Colors.grey),
                                                ])).reduce((a, b) => a + b))
                                    .reduce((a, b) => a + b),
                                onExpansionChanged: (expanded) {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  setState(() => item['expanded'] = expanded);
                                }));
                      },
                      key: ValueKey('$snapshot.data $_searchMode'),
                    );
                  })),
        ));
  }
}
