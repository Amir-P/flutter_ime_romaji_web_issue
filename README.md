# flutter_ime_romaji_web_issue

An example to show the issue with Flutter's IME for Japenese Romaji on Web

## Deltas

```
macOS: 
TextEditingDeltaInsertion: start: 0, end: 0, data: k
TextEditingDeltaInsertion: start: 1, end: 0, data: y
TextEditingDeltaReplacement: start: 0, end: 2, data: きょ
TextEditingDeltaInsertion: start: 2, end: 0, data: う
TextEditingDeltaInsertion: start: 3, end: 0, data: h
TextEditingDeltaReplacement: start: 0, end: 4, data: きょうは
TextEditingDeltaReplacement: start: 0, end: 4, data: 今日は

Chrome:
TextEditingDeltaInsertion: start: 0, end: 0, data: k
TextEditingDeltaInsertion: start: 1, end: 0, data: y
TextEditingDeltaReplacement: start: 0, end: 2, data: きょ
TextEditingDeltaInsertion: start: 2, end: 0, data: う
TextEditingDeltaInsertion: start: 3, end: 0, data: h
TextEditingDeltaReplacement: start: 0, end: 4, data: きょうは
TextEditingDeltaInsertion: start: 4, end: 0, data: 今日は
```