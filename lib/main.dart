import 'package:basic_socet/page/group_connection.dart';
import 'package:basic_socet/page/pear_to_pear_connection.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: GroupMeetingPage(),
    );
  }
}
