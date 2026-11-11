import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qcf_quran_plus/qcf_quran_plus.dart';

import '../constants/app_colors.dart';
import '../services/mushaf_loader.dart';
import '../services/quran_service.dart';
import '../services/storage_service.dart';
import '../services/text_normalizer.dart';

/// A distraction-free writing page. No memorization check or grading.
class MushafWritingScreen extends StatefulWidget {
  const MushafWritingScreen({super.key, this.initialPage = 1});

  final int initialPage;

  @override
  State<MushafWritingScreen> createState() => _MushafWritingScreenState();
}

class _MushafWritingScreenState extends State<MushafWritingScreen> {
  late final PageController _pageController;
  int? _lastMushafPage;
  bool _hasPositionedMushaf = false;
  final _LiveWritingController _writingController = _LiveWritingController();
  final FocusNode _writingFocus = FocusNode();
  late int _page;
  bool _loading = true;
  bool _loadFailed = false;
  double _verseOpacity = 0.30;
  Timer? _saveDebounce;
  bool _saved = true;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage.clamp(1, 604).toInt();
    // Start at page zero; QuranPageView must attach before we jump to the
    // requested Mushaf page (same lifecycle used by the working test screen).
    _pageController = PageController(initialPage: 0);
    _preparePage();
  }

  Future<void> _preparePage() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadFailed = false;
      });
    }
    final requestedPage = _page;
    try {
      await MushafLoader.ensureReady(requestedPage);
      if (!mounted || requestedPage != _page) return;
      final storage = context.read<StorageService>();
      await storage.saveLastWritingPage(requestedPage);
      final draft = storage.getWritingDraft(requestedPage);
      _writingController.expectedWords = _expectedWordsForPage(requestedPage);
      final savedOpacity = storage.getWritingOpacity();
      _writingController.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
      setState(() {
        _loading = false;
        _saved = true;
        _verseOpacity = savedOpacity;
      });
    } catch (error, stackTrace) {
      debugPrint('LAW H writing page load failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted || requestedPage != _page) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  List<String> _expectedWordsForPage(int pageNumber) {
    final quran = context.read<QuranService>();
    final words = <String>[];
    for (final ayah in quran.ayahs) {
      if (getPageNumber(ayah.surah, ayah.ayah) == pageNumber) {
        words.addAll(ayah.text.split(RegExp(r'\s+')).where((word) => word.isNotEmpty));
      }
    }
    return words;
  }

  String get _liveFeedback {
    final typed = _writingController.text.trimRight();
    if (typed.isEmpty) return 'سيظهر التنبيه أثناء الكتابة';
    final words = typed.split(RegExp(r'\s+'));
    final index = words.length - 1;
    if (index >= _writingController.expectedWords.length) return 'تجاوزت كلمات الصفحة';
    final actual = TextNormalizer.normalize(words.last);
    final expected = TextNormalizer.normalize(_writingController.expectedWords[index]);
    final partial = !_writingController.text.endsWith(' ');
    if (actual == expected || (partial && actual.isNotEmpty && expected.startsWith(actual))) {
      return 'الكلمة الحالية مطابقة';
    }
    return 'انتبه: الكلمة الحالية مختلفة عن نص الصفحة';
  }

  bool get _liveWordIsCorrect =>
      _liveFeedback == 'الكلمة الحالية مطابقة' ||
      _liveFeedback == 'سيظهر التنبيه أثناء الكتابة';

  Future<void> _saveDraftNow() async {
    _saveDebounce?.cancel();
    await context.read<StorageService>().saveWritingDraft(
      _page,
      _writingController.text,
    );
    if (mounted) setState(() => _saved = true);
  }

  void _scheduleSave(String value) {
    _saveDebounce?.cancel();
    setState(() => _saved = false);
    _saveDebounce = Timer(const Duration(milliseconds: 450), _saveDraftNow);
  }

  Future<void> _goToPage(int value) async {
    final next = value.clamp(1, 604).toInt();
    if (next == _page) return;
    await _saveDraftNow();
    if (!mounted) return;
    await context.read<StorageService>().saveLastWritingPage(next);
    if (!mounted) return;
    setState(() {
      _page = next;
      _writingController.clear();
      _loading = true;
    });
    _lastMushafPage = null;
    _preparePage();
  }

  Future<void> _clearWriting() async {
    _saveDebounce?.cancel();
    _writingController.clear();
    await context.read<StorageService>().saveWritingDraft(_page, '');
    if (mounted) setState(() => _saved = true);
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _pageController.dispose();
    _writingController.dispose();
    _writingFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // QuranPageView may attach its internal PageView after this State's first
    // build. Jump only after that attachment, otherwise some package versions
    // render a blank page when given a non-zero initialPage.
    if (_lastMushafPage != _page) {
      _lastMushafPage = _page;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          if (_hasPositionedMushaf) {
            _pageController.animateToPage(_page - 1,
              duration: const Duration(milliseconds: 360), curve: Curves.easeInOutCubic);
          } else {
            _pageController.jumpToPage(_page - 1);
            _hasPositionedMushaf = true;
          }
          debugPrint('LAW H writing Mushaf page positioned: $_page');
        } else {
          debugPrint('LAW H writing Mushaf controller not attached for page $_page');
        }
      });
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final paper = isDark ? const Color(0xFF1D2924) : const Color(0xFFFFFDF7);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        // Keep the Mushaf viewport at a fixed size when the keyboard opens.
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: const Text('الكتابة فوق المصحف'),
          actions: [
            IconButton(
              tooltip: 'مسح الكتابة',
              onPressed: _clearWriting,
              icon: const Icon(Icons.cleaning_services_rounded),
            ),
          ],
        ),
        body: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              color: isDark ? const Color(0xFF14231D) : const Color(0xFFF1EBDD),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.auto_stories_rounded, color: AppColors.accentGold),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'اكتب مباشرة فوق الآيات — تُحفظ كتابتك تلقائياً',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(
                        _saved ? Icons.cloud_done_rounded : Icons.cloud_upload_outlined,
                        size: 17,
                        color: _saved ? AppColors.primaryGreenLight : AppColors.accentGold,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _saved ? 'محفوظ' : 'جارٍ الحفظ',
                        style: const TextStyle(fontSize: 11, color: AppColors.accentGold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Icon(_liveWordIsCorrect ? Icons.check_circle_outline_rounded : Icons.warning_amber_rounded,
                        size: 15, color: _liveWordIsCorrect ? AppColors.primaryGreenLight : AppColors.mistakeRed),
                      const SizedBox(width: 6),
                      Expanded(child: Text(_liveFeedback, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: _liveWordIsCorrect ? AppColors.primaryGreenLight : AppColors.mistakeRed))),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      const Icon(Icons.menu_book_rounded, size: 17, color: AppColors.accentGold),
                      const SizedBox(width: 7),
                      const Text('السورة', style: TextStyle(fontSize: 12)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Consumer<QuranService>(
                          builder: (context, quran, _) => DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              isExpanded: true,
                              value: quran.surahs.any((s) => s.id == _selectedSurahId)
                                  ? _selectedSurahId
                                  : (quran.surahs.isNotEmpty ? quran.surahs.first.id : null),
                              hint: const Text('اختر السورة'),
                              items: quran.surahs.map((surah) => DropdownMenuItem<int>(
                                value: surah.id,
                                child: Text('${surah.name}  ·  ${surah.ayahsCount} آية',
                                  overflow: TextOverflow.ellipsis),
                              )).toList(),
                              onChanged: (id) {
                                if (id == null) return;
                                final selected = quran.getSurah(id);
                                if (selected == null) return;
                                setState(() => _selectedSurahId = id);
                                _goToPage(selected.startPage);
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.visibility_outlined, size: 17, color: AppColors.accentGold),
                      const SizedBox(width: 7),
                      const Text('وضوح الآيات', style: TextStyle(fontSize: 12)),
                      Expanded(
                        child: Slider(
                          value: _verseOpacity,
                          min: 0.08,
                          max: 0.75,
                          divisions: 13,
                          activeColor: AppColors.accentGold,
                          onChanged: (value) {
                            setState(() => _verseOpacity = value);
                            context.read<StorageService>().saveWritingOpacity(value);
                          },
                        ),
                      ),
                      Text(
                        '${(_verseOpacity * 100).round()}٪',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: paper,
                      border: Border.all(
                        color: AppColors.accentGold.withOpacity(0.65),
                        width: 1.2,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Opacity(
                          // Fade only the Mushaf reference layer, not the
                          // writing field or the whole page container.
                          opacity: _verseOpacity,
                          child: IgnorePointer(
                            child: QuranPageView(
                              pageController: _pageController,
                              highlights: const <HighlightVerse>[],
                              isDarkMode: isDark,
                              isTajweed: false,
                              enableTwoPageLayout: false,
                              deferNewPages: false,
                              pageBackgroundColor: paper,
                              onPageChanged: (pageNumber) {
                                if (pageNumber != _page) {
                                  _page = pageNumber;
                                  context.read<StorageService>().saveLastWritingPage(pageNumber);
                                }
                                // Load the selected page font on demand; nearby pages
                                // are loaded only as the user navigates to them.
                                _writingController.expectedWords = _expectedWordsForPage(pageNumber);
                                MushafLoader.ensureReady(pageNumber).catchError((error) {
                                  debugPrint('LAW H page font retry needed ($pageNumber): $error');
                                });
                              },
                            ),
                          ),
                        ),
                        if (!_loading && !_loadFailed)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                            child: TextField(
                              controller: _writingController,
                              focusNode: _writingFocus,
                              expands: true,
                              maxLines: null,
                              minLines: null,
                              textDirection: TextDirection.rtl,
                              textAlign: TextAlign.center,
                              textAlignVertical: TextAlignVertical.top,
                              keyboardType: TextInputType.multiline,
                              autocorrect: false,
                              enableSuggestions: false,
                              onChanged: (value) {
                                _scheduleSave(value);
                              },
                              cursorColor: AppColors.accentGold,
                              style: TextStyle(
                                fontFamily: 'QuranHafs',
                                fontSize: 23,
                                height: 2.05,
                                color: isDark
                                    ? const Color(0xFFFFD98A)
                                    : const Color(0xFF14513B),
                              ),
                              decoration: InputDecoration(
                                // ThemeData globally fills text fields. Disable it here:
                                // this editor must be a transparent overlay over the Mushaf.
                                filled: false,
                                fillColor: Colors.transparent,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                hintText: 'اكتب هنا…',
                                hintStyle: TextStyle(
                                  color: (isDark ? Colors.white : Colors.black)
                                      .withOpacity(0.22),
                                  fontSize: 18,
                                ),
                              ),
                            ),
                          ),
                        if (_loading)
                          Align(
                            alignment: Alignment.topCenter,
                            child: IgnorePointer(
                              child: Container(
                                margin: const EdgeInsets.all(12),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                decoration: BoxDecoration(
                                  color: paper.withOpacity(0.78),
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(color: AppColors.accentGold.withOpacity(0.45)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(width: 15, height: 15,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentGold)),
                                    SizedBox(width: 9),
                                    Text('جارٍ تحميل خط الصفحة…', style: TextStyle(fontSize: 12)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (_loadFailed)
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.error_outline_rounded,
                                      size: 42, color: Colors.redAccent),
                                  const SizedBox(height: 10),
                                  const Text('تعذّر تحميل صفحة المصحف'),
                                  const SizedBox(height: 12),
                                  ElevatedButton.icon(
                                    onPressed: _preparePage,
                                    icon: const Icon(Icons.refresh_rounded),
                                    label: const Text('إعادة المحاولة'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 5, 12, 10),
                child: Row(
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'الصفحة السابقة',
                      onPressed: _page > 1 ? () => _goToPage(_page - 1) : null,
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _showPagePicker(context),
                        icon: const Icon(Icons.menu_book_rounded),
                        label: const Text('اختيار الصفحة'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'الصفحة التالية',
                      onPressed: _page < 604 ? () => _goToPage(_page + 1) : null,
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPagePicker(BuildContext context) async {
    final controller = TextEditingController(text: _page.toString());
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('الانتقال إلى صفحة'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'من 1 إلى 604',
            prefixIcon: Icon(Icons.menu_book_rounded),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text.trim());
              if (parsed != null && parsed >= 1 && parsed <= 604) {
                Navigator.pop(dialogContext, parsed);
              }
            },
            child: const Text('انتقال'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) _goToPage(value);
  }
}


/// Colors each typed word immediately against the words on the currently
/// displayed Mushaf page. Partial prefixes are accepted while the user types.
class _LiveWritingController extends TextEditingController {
  List<String> expectedWords = const <String>[];

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final spans = <InlineSpan>[];
    final matches = RegExp(r'\s+|\S+').allMatches(text);
    var wordIndex = 0;
    for (final match in matches) {
      final token = match.group(0)!;
      if (RegExp(r'^\s+$').hasMatch(token)) {
        spans.add(TextSpan(text: token, style: base));
        continue;
      }
      final normalized = TextNormalizer.normalize(token);
      final isLastPartial = wordIndex == expectedWordCount - 1 && !text.endsWith(' ');
      final expected = wordIndex < expectedWords.length
          ? TextNormalizer.normalize(expectedWords[wordIndex])
          : '';
      final correct = wordIndex < expectedWords.length &&
          (normalized == expected ||
              (isLastPartial && normalized.isNotEmpty && expected.startsWith(normalized)));
      spans.add(TextSpan(
        text: token,
        style: base.copyWith(
          color: correct ? base.color : const Color(0xFFE05252),
        ),
      ));
      wordIndex++;
    }
    return TextSpan(style: base, children: spans);
  }

  int get expectedWordCount {
    final typed = text.trimRight();
    return typed.isEmpty ? 0 : typed.split(RegExp(r'\s+')).length;
  }
}
