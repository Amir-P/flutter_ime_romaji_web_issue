import 'package:flutter/material.dart' hide EditableText;
import 'package:flutter_ime_romaji_web_issue/editable.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatelessWidget {
  const MyHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 200,
              height: 50,
              color: Colors.grey,
              child: EditableText(
                backgroundCursorColor: Colors.red,
                controller: TextEditingController(),
                cursorColor: Colors.red,
                focusNode: FocusNode(),
                style: const TextStyle(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
