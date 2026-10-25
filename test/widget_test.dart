import 'package:flutter_test/flutter_test.dart';
import 'package:nummwe3/comment_filter.dart';
import 'package:nummwe3/username_filter.dart';

void main() {
  test('username filter preserves valid names', () {
    final result = UsernameFilter.validate('Test_User');
    expect(result.isValid, isTrue);
    expect(result.normalized, 'Test_User');
    expect(UsernameFilter.comparisonKey(result.normalized), 'test_user');
  });

  test('username filter blocks reserved names', () {
    final result = UsernameFilter.validate('admin');
    expect(result.isValid, isFalse);
    expect(result.error, UsernameValidationError.reservedOrOffensive);
  });

  test('comment filter blocks abusive language', () {
    final result = CommentFilter.validate('you are a bitch');
    expect(result.isAllowed, isFalse);
    expect(result.issue, CommentModerationIssue.abusiveLanguage);
  });

  test('comment filter allows regular comments', () {
    final result = CommentFilter.validate('Cool shot!');
    expect(result.isAllowed, isTrue);
    expect(result.sanitized, 'Cool shot!');
  });
}
