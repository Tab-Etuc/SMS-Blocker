import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final SmsQuery _query = SmsQuery();
  final List<SmsMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();
  int _startIndex = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);
    _loadSMS();
  }

  _loadSMS() async {
    if ((await Permission.sms.status).isGranted) {
      final messages = await _query.querySms(
        kinds: [SmsQueryKind.inbox, SmsQueryKind.sent],
        count: 10,
        start: _startIndex,
      );
      if (messages.isNotEmpty) {
        setState(() {
          _messages.addAll(messages);
          _startIndex += messages.length;
        });
      } else {
        _scrollController.removeListener(_scrollListener);
      }
    } else {
      await Permission.sms.request();
    }
  }

  _scrollListener() {
    if (_scrollController.position.atEdge &&
        _scrollController.position.pixels != 0) {
      _loadSMS();
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_scrollListener)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SMS Blocker',
      theme: ThemeData(primarySwatch: Colors.teal),
      home: Scaffold(
        appBar: AppBar(title: const Text('收件匣')),
        body: Container(
          padding: const EdgeInsets.all(10.0),
          child: _messages.isNotEmpty
              ? _MessagesListView(
                  messages: _messages,
                  controller: _scrollController,
                )
              : Center(
                  child: Text(
                    '查無簡訊...',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _loadSMS,
          child: const Icon(Icons.refresh),
        ),
      ),
    );
  }
}

Future<String> _sendPostRequest(String messageBody) async {
  const url = 'https://api.cofacts.tw/graphql';
  final headers = {'Content-Type': 'application/json; charset=UTF-8'};
  final body = json.encode({
    "query":
        "{ ListArticles(filter: { moreLikeThis: { like: \"$messageBody\" } }, first: 1) { edges { node { id, text, articleReplies { replyType } } } } }"
  });

  final response = await http.post(
    Uri.parse(url),
    headers: headers,
    body: body,
  );

  if (response.statusCode == 200) {
    var responseData = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    if (responseData["data"]["ListArticles"]["edges"] != null &&
        responseData["data"]["ListArticles"]["edges"].isNotEmpty) {
      if (similarityPercentage(
              responseData["data"]["ListArticles"]["edges"][0]["node"]["text"]
                  .replaceAll(' ', ''),
              messageBody.replaceAll(' ', '')) >
          90) {
        int count = 0;
        var articleReplies = responseData["data"]["ListArticles"]["edges"][0]
            ["node"]["articleReplies"];
        for (var reply in articleReplies) {
          if (reply["replyType"] == "RUMOR") {
            count++;
          }
        }
        if (count > 0) {
          return '此則簡訊共有${count}個人認為是詐騙訊息！\n詳情請見：|${responseData["data"]["ListArticles"]["edges"][0]["node"]["id"]}';
        }
      }
    }
  }
  return '';
}

int levenshteinDistance(String s1, String s2) {
  if (s1 == s2) {
    return 0;
  }
  if (s1.isEmpty) {
    return s2.length;
  }
  if (s2.isEmpty) {
    return s1.length;
  }

  List<List<int>> matrix = List.generate(
      s1.length + 1, (i) => List.generate(s2.length + 1, (j) => 0));

  for (int i = 0; i <= s1.length; i++) {
    matrix[i][0] = i;
  }
  for (int j = 0; j <= s2.length; j++) {
    matrix[0][j] = j;
  }

  for (int i = 1; i <= s1.length; i++) {
    for (int j = 1; j <= s2.length; j++) {
      int cost = (s1[i - 1] == s2[j - 1]) ? 0 : 1;

      matrix[i][j] = [
        matrix[i - 1][j] + 1,
        matrix[i][j - 1] + 1,
        matrix[i - 1][j - 1] + cost
      ].reduce((value, element) => value < element ? value : element);
    }
  }

  return matrix[s1.length][s2.length];
}

double similarityPercentage(String s1, String s2) {
  int distance = levenshteinDistance(s1, s2);
  int maxLength = (s1.length > s2.length) ? s1.length : s2.length;

  return (1.0 - distance / maxLength) * 100;
}

class _MessagesListView extends StatefulWidget {
  final List<SmsMessage> messages;
  final ScrollController controller;

  const _MessagesListView({
    Key? key,
    required this.messages,
    required this.controller,
  }) : super(key: key);

  @override
  _MessagesListViewState createState() => _MessagesListViewState();
}

class _MessagesListViewState extends State<_MessagesListView> {
  final Map<int, Future<String>> _futures = {};

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: widget.controller,
      shrinkWrap: true,
      itemCount: widget.messages.length,
      itemBuilder: (context, i) {
        final message = widget.messages[i];
        final date = message.date
            .toString()
            .substring(0, message.date.toString().length - 4);
        final truncatedBody = message.body!.length > 15
            ? message.body!.substring(0, 15)
            : message.body;

        return ExpansionTile(
          title: Text('${message.sender} [$date]'),
          subtitle: Text(
              '${truncatedBody}${message.body!.length > 15 ? '...[點擊展開]' : ''}'),
          onExpansionChanged: (expanded) {
            if (expanded && !_futures.containsKey(i)) {
              setState(() {
                _futures[i] = _sendPostRequest(message.body!);
              });
            }
          },
          children: [
            if (_futures.containsKey(i))
              FutureBuilder<String>(
                future: _futures[i],
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done) {
                    if (snapshot.hasError) {
                      return Text('Error: ${snapshot.error}');
                    }
                    if (snapshot.data == '') {
                      return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16.0, vertical: 8.0),
                          child: Text(message.body!));
                    } else {
                      List<String> parts = snapshot.data!.split('|');
                      String text = parts[0];
                      String id = parts[1];
                      return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16.0, vertical: 8.0),
                          child: Column(children: <Widget>[
                            Text(text),
                            ElevatedButton(
                              onPressed: () async {
                                final Uri url = Uri.parse(
                                    'https://cofacts.tw/article/${id}');

                                if (await canLaunchUrl(url)) {
                                  await launchUrl(url);
                                }
                              },
                              child: Text('https://cofacts.tw/article/${id}'),
                            ),
                            Text(message.body!)
                          ]));
                    }
                  } else {
                    return const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: CircularProgressIndicator(),
                    );
                  }
                },
              ),
          ],
        );
      },
    );
  }
}
