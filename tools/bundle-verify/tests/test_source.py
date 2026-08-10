#!/usr/bin/env python3
"""test_source.py — Python-stdlib tests for extract_source.py (Check A2).

Validates:
  1. The Shen s-expression reader (mirrors shen-kl-helpers.shen's extended
     reader + load.shen's parse-string semantics).
  2. Clause splitting / pattern analysis (nonlinear + tuple patterns).
  3. unsafe_construct detection (defmacro/datatype/freeze/thaw/cond/case).
  4. End-to-end synthetic-source fact emission.

Runs WITHOUT souffle or clang — pure Python stdlib + unittest.
"""

import csv
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS_DIR))

import extract_source as src


def parse_all(text):
    """Parse text and return just the forms (drop line numbers)."""
    return [form for _line, form in src.ShenReader(text).parse_all()]


def analyze(text, defined=None):
    """Run the analyzer over a synthetic source string, return the analyzer."""
    return src.SourceAnalyzer(defined_funcs=set(defined or ())).analyze(text, "t.shen")


def read_csv(path):
    rows = []
    with open(path) as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            rows.append(tuple(row))
    return rows, header


# ── Reader: atoms ────────────────────────────────────────────────────

class TestReaderAtoms(unittest.TestCase):
    def test_symbol_atom(self):
        self.assertEqual(parse_all("foo"), ["foo"])

    def test_lowercase_symbol(self):
        self.assertEqual(parse_all("abc123"), ["abc123"])

    def test_positive_number(self):
        self.assertEqual(parse_all("42"), [42])

    def test_negative_number(self):
        self.assertEqual(parse_all("-7"), [-7])

    def test_bare_minus_is_symbol(self):
        self.assertEqual(parse_all("-"), ["-"])

    def test_case_preserved(self):
        self.assertEqual(parse_all("FooBar"), ["FooBar"])

    def test_mixed_symbol(self):
        self.assertEqual(parse_all("a-b_c"), ["a-b_c"])


# ── Reader: strings ──────────────────────────────────────────────────

class TestReaderStrings(unittest.TestCase):
    def test_plain_string(self):
        self.assertEqual(parse_all('"hello"'), ["hello"])

    def test_no_escape_backslash_is_literal(self):
        self.assertEqual(parse_all(r'"a\nb"'), ["a\\nb"])

    def test_empty_string(self):
        self.assertEqual(parse_all('""'), [""])

    def test_string_with_spaces(self):
        self.assertEqual(parse_all('"a b c"'), ["a b c"])

    def test_unterminated_string_raises(self):
        with self.assertRaises(src.ReadError):
            src.ShenReader('"abc').parse_all()


# ── Reader: lists / brackets / dotted / sigs ─────────────────────────

class TestReaderLists(unittest.TestCase):
    def test_empty_paren_list(self):
        self.assertEqual(parse_all("()"), [[]])

    def test_paren_list(self):
        self.assertEqual(parse_all("(a b c)"), [["a", "b", "c"]])

    def test_empty_bracket_list(self):
        self.assertEqual(parse_all("[]"), [[]])

    def test_bracket_list(self):
        self.assertEqual(parse_all("[a b c]"), [["a", "b", "c"]])

    def test_nested_lists(self):
        self.assertEqual(parse_all("(a (b (c)))"), [["a", ["b", ["c"]]]])

    def test_mixed_bracket_in_paren(self):
        self.assertEqual(parse_all("(f [a b])"), [["f", ["a", "b"]]])

    def test_dotted_bracket_list(self):
        self.assertEqual(parse_all("[X | Rest]"), [["cons", "X", "|", "Rest"]])

    def test_dotted_multi_element(self):
        self.assertEqual(parse_all("[a b | c]"), [["cons", "a", "b", "|", "c"]])

    def test_paren_bar_is_ordinary_atom(self):
        # `|` inside ( ) is an ordinary atom, not an improper-cdr marker.
        self.assertEqual(parse_all("(a | b)"), [["a", "|", "b"]])

    def test_type_sig(self):
        self.assertEqual(parse_all("{ A --> B }"), [["{", "A", "-->", "B", "}"]])

    def test_triple_bracket_nesting(self):
        self.assertEqual(parse_all("[[[= Slot Pat]]]"),
                         [[[["=", "Slot", "Pat"]]]])

    def test_multiple_forms(self):
        forms = parse_all("(a) b [c]")
        self.assertEqual(forms, [["a"], "b", ["c"]])

    def test_unterminated_list_raises(self):
        with self.assertRaises(src.ReadError):
            src.ShenReader("(a b").parse_all()

    def test_unterminated_sig_raises(self):
        with self.assertRaises(src.ReadError):
            src.ShenReader("{ a b").parse_all()

    def test_unexpected_close_raises(self):
        with self.assertRaises(src.ReadError):
            src.ShenReader(")").parse_all()

    def test_close_bracket_raises(self):
        with self.assertRaises(src.ReadError):
            src.ShenReader("[a] )").parse_all()


# ── Reader: comments ─────────────────────────────────────────────────

class TestReaderComments(unittest.TestCase):
    def test_line_comment(self):
        self.assertEqual(parse_all("(a) \\\\ comment\n(b)"), [["a"], ["b"]])

    def test_block_comment(self):
        self.assertEqual(parse_all("(a) \\* x y *\\ (b)"), [["a"], ["b"]])

    def test_block_comment_multiline(self):
        self.assertEqual(parse_all("(a) \\* x\n y *\\ (b)"), [["a"], ["b"]])

    def test_unterminated_block_comment_raises(self):
        with self.assertRaises(src.ReadError):
            src.ShenReader("(a) \\* nope").parse_all()

    def test_line_numbers_tracked(self):
        reader = src.ShenReader("(a)\n(b)\n(c)")
        lines = [line for line, _ in reader.parse_all()]
        self.assertEqual(lines, [1, 2, 3])


# ── Pattern analysis ─────────────────────────────────────────────────

class TestPatternAnalysis(unittest.TestCase):
    def test_nonlinear_simple(self):
        a = analyze("(define f X X -> X)")
        self.assertIn(("t.shen", 1, "X"), a.nonlinear)

    def test_nonlinear_nested_in_list(self):
        a = analyze("(define f X [X | Rest] -> X)")
        self.assertIn(("t.shen", 1, "X"), a.nonlinear)

    def test_wildcard_ok(self):
        a = analyze("(define f _ _ -> 0)")
        self.assertEqual(len(a.nonlinear), 0)

    def test_distinct_ok(self):
        a = analyze("(define f A B C -> A)")
        self.assertEqual(len(a.nonlinear), 0)

    def test_across_clauses_ok(self):
        a = analyze("(define f X -> X  X -> 0)")
        self.assertEqual(len(a.nonlinear), 0)

    def test_cons_pattern_ok(self):
        a = analyze("(define f [X | Rest] -> X)")
        self.assertEqual(len(a.nonlinear), 0)

    def test_tuple_pattern_detected(self):
        a = analyze("(define f (@p A B) -> A)")
        self.assertIn(("t.shen", 1), a.tuple_rows)

    def test_tuple_constructor_in_body_ok(self):
        # @p used as a body expression, not a pattern, is fine.
        a = analyze("(define f A B -> (@p A B))")
        self.assertEqual(len(a.tuple_rows), 0)
        self.assertEqual(len(a.unsafe), 0)


# ── unsafe_construct ─────────────────────────────────────────────────

class TestUnsafeConstruct(unittest.TestCase):
    def test_datatype_detected(self):
        a = analyze("(datatype foo X -> X)")
        self.assertIn(("t.shen", 1, "datatype"), a.unsafe)

    def test_defmacro_detected(self):
        a = analyze("(defmacro foo X -> X)")
        self.assertIn(("t.shen", 1, "defmacro"), a.unsafe)

    def test_freeze_detected(self):
        a = analyze("(define f X -> (freeze X))")
        self.assertIn(("t.shen", 1, "freeze"), a.unsafe)

    def test_thaw_detected(self):
        a = analyze("(define f X -> (thaw X))")
        self.assertIn(("t.shen", 1, "thaw"), a.unsafe)

    def test_cond_detected(self):
        a = analyze("(define f X -> (cond X))")
        self.assertIn(("t.shen", 1, "cond"), a.unsafe)

    def test_case_detected(self):
        a = analyze("(define f X -> (case X))")
        self.assertIn(("t.shen", 1, "case"), a.unsafe)

    def test_define_safe(self):
        a = analyze("(define f X -> X)")
        self.assertEqual(len(a.unsafe), 0)

    def test_lambda_safe(self):
        a = analyze("(define f X -> (lambda Y Y))")
        self.assertEqual(len(a.unsafe), 0)

    def test_let_safe(self):
        a = analyze("(define f X -> (let Y X Y))")
        self.assertEqual(len(a.unsafe), 0)

    def test_where_safe(self):
        a = analyze("(define f X -> true where (= X 0))")
        self.assertEqual(len(a.unsafe), 0)

    def test_tc_safe(self):
        a = analyze("(tc -)")
        self.assertEqual(len(a.unsafe), 0)

    def test_load_safe(self):
        a = analyze('(load "shen/util.shen")')
        self.assertEqual(len(a.unsafe), 0)

    def test_unsafe_nested_in_lambda(self):
        a = analyze("(define f X -> (lambda Y (cond Y)))")
        self.assertIn(("t.shen", 1, "cond"), a.unsafe)

    def test_unsafe_nested_in_let(self):
        a = analyze("(define f X -> (let Y X (case Y)))")
        self.assertIn(("t.shen", 1, "case"), a.unsafe)

    def test_unsafe_nested_in_if(self):
        a = analyze("(define f X -> (if X (thaw X) 0))")
        self.assertIn(("t.shen", 1, "thaw"), a.unsafe)

    def test_bracket_data_head_not_flagged(self):
        # [number X] is list DATA, not a call — its head is not unsafe.
        a = analyze("(define f X -> [number X])")
        self.assertEqual(len(a.unsafe), 0)


# ── End-to-end ───────────────────────────────────────────────────────

class TestEndToEnd(unittest.TestCase):
    def test_synthetic_source_all_three(self):
        text = (
            "(datatype bad X -> X)\n"
            "(define f X [X | Rest] -> (freeze X) where (= X 0))\n"
            "(define g (@p A B) -> A)\n"
        )
        a = analyze(text, defined={"f", "g"})
        self.assertIn(("t.shen", 1, "datatype"), a.unsafe)
        self.assertIn(("t.shen", 2, "freeze"), a.unsafe)
        self.assertIn(("t.shen", 2, "X"), a.nonlinear)
        self.assertIn(("t.shen", 3), a.tuple_rows)

    def test_write_facts_produces_relations(self):
        a = analyze("(datatype bad X -> X)\n(define f X -> X)", defined={"f"})
        with tempfile.TemporaryDirectory() as td:
            src.write_facts(td, a, ["t.shen"])

            rows, header = read_csv(Path(td) / "source_file.csv")
            self.assertEqual(header, ["name"])
            self.assertIn(("t.shen",), rows)

            rows, header = read_csv(Path(td) / "unsafe_construct.csv")
            self.assertEqual(header, ["file", "line", "head"])
            self.assertIn(("t.shen", "1", "datatype"), rows)

            rows, header = read_csv(Path(td) / "nonlinear_pattern.csv")
            self.assertEqual(header, ["file", "line", "var"])

            rows, header = read_csv(Path(td) / "tuple_pattern.csv")
            self.assertEqual(header, ["file", "line"])

    def test_source_file_has_twelve_entries(self):
        # The constant enumerates the 12 files from serialize-reduced.shen:28-43.
        self.assertEqual(len(src.SOURCE_FILES), 12)

    def test_is_variable(self):
        self.assertTrue(src.is_variable("X"))
        self.assertTrue(src.is_variable("Rest"))
        self.assertFalse(src.is_variable("_"))
        self.assertFalse(src.is_variable("cons"))
        self.assertFalse(src.is_variable(""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
