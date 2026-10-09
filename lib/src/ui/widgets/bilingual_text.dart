import 'package:flutter/widgets.dart';

/// 简单的双语文本：中文环境显示中文，其他显示英文。
/// 用于新增页面，避免改动 12 套 l10n 生成文件。
String tr(BuildContext context, String zh, String en) {
  try {
    if (Localizations.localeOf(context).languageCode == 'zh') return zh;
  } catch (_) {}
  return en;
}
