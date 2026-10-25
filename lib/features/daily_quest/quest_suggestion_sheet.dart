import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../shared.dart';
import 'daily_quest_service.dart';

/// Bottom sheet that lets users propose their own daily quest.
/// Suggestions land in `quest_suggestions` (status `pending`) and only go
/// live after manual review — never directly into the rotation.
Future<void> showQuestSuggestionSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _QuestSuggestionSheet(),
  );
}

class _QuestSuggestionSheet extends StatefulWidget {
  const _QuestSuggestionSheet();

  @override
  State<_QuestSuggestionSheet> createState() => _QuestSuggestionSheetState();
}

class _QuestSuggestionSheetState extends State<_QuestSuggestionSheet> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  bool _submitting = false;

  static const int _titleMax = 80;
  static const int _descriptionMax = 200;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_submitting &&
      _titleController.text.trim().length >= 3 &&
      _descriptionController.text.trim().length >= 10;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _submitting = true);

    String? errorText;
    try {
      await DailyQuestService.submitSuggestion(
        title: _titleController.text,
        description: _descriptionController.text,
      );
    } on QuestSuggestionException catch (e) {
      errorText = switch (e.reason) {
        QuestSuggestionError.rateLimited => t(
          'Du hast heute schon genug Vorschläge eingereicht — versuch es morgen wieder!',
          'You already sent enough suggestions today — try again tomorrow!',
        ),
        QuestSuggestionError.tooShort => t(
          'Titel oder Beschreibung sind zu kurz.',
          'Title or description is too short.',
        ),
        QuestSuggestionError.notSignedIn => t(
          'Bitte melde dich erneut an.',
          'Please sign in again.',
        ),
      };
    } catch (_) {
      errorText = t(
        'Senden fehlgeschlagen. Prüfe deine Verbindung und versuch es nochmal.',
        'Sending failed. Check your connection and try again.',
      );
    }

    if (!mounted) return;
    setState(() => _submitting = false);

    final messenger = ScaffoldMessenger.of(context);
    if (errorText != null) {
      messenger.showSnackBar(SnackBar(content: Text(errorText)));
      return;
    }

    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          t(
            'Danke! Wir prüfen deine Quest — wenn sie live geht, steht dein Name dran. 💡',
            'Thanks! We will review your quest — if it goes live, it carries your name. 💡',
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration({
    required String hint,
    required int maxLength,
    required int currentLength,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: GoogleFonts.inter(
        color: Colors.white.withValues(alpha: 0.35),
        fontSize: 14,
      ),
      counterText: '$currentLength/$maxLength',
      counterStyle: GoogleFonts.inter(
        color: Colors.white.withValues(alpha: 0.4),
        fontSize: 11,
      ),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.05),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: appGreen, width: 1.4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: const BoxDecoration(
          color: Color(0xFF161A18),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                t('💡 Deine Quest-Idee', '💡 Your quest idea'),
                style: GoogleFonts.inter(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                t(
                  'Schlag eine Daily Quest vor. Wenn sie es in die Rotation schafft, sehen alle deinen Namen dran.',
                  'Suggest a daily quest. If it makes the rotation, everyone sees your name on it.',
                ),
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.6),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                maxLength: _titleMax,
                style: GoogleFonts.inter(color: Colors.white, fontSize: 14),
                onChanged: (_) => setState(() {}),
                decoration: _fieldDecoration(
                  hint: t(
                    'Titel — z. B. „Gelbes Auto“',
                    'Title — e.g. “Yellow Car”',
                  ),
                  maxLength: _titleMax,
                  currentLength: _titleController.text.length,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _descriptionController,
                maxLength: _descriptionMax,
                maxLines: 3,
                style: GoogleFonts.inter(color: Colors.white, fontSize: 14),
                onChanged: (_) => setState(() {}),
                decoration: _fieldDecoration(
                  hint: t(
                    'Was genau soll man fotografieren?',
                    'What exactly should people photograph?',
                  ),
                  maxLength: _descriptionMax,
                  currentLength: _descriptionController.text.length,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _canSubmit ? _submit : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: appGreen,
                    disabledBackgroundColor: Colors.white.withValues(
                      alpha: 0.08,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _submitting
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Color(0xFF10160F),
                            ),
                          ),
                        )
                      : Text(
                          t('Vorschlag senden', 'Send suggestion'),
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF10160F),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
