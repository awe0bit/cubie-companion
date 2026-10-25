"""Cross-platform project structure checks, not a substitute for Xcode."""
import ast
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def main():
    python_files = list((ROOT/'backend').rglob('*.py')) + list((ROOT/'deploy').glob('*.py'))
    for path in python_files:
        ast.parse(path.read_text(encoding='utf-8'), filename=str(path), feature_version=(3, 9))
    project = (ROOT/'ios/Cubie.xcodeproj/project.pbxproj').read_text()
    identifiers = re.findall(r'^\s*([A-F0-9]{24}) = \{', project, re.M)
    assert len(identifiers) == len(set(identifiers)), 'duplicate_pbx_id'
    assert set(re.findall(r'\b[A-F0-9]{24}\b', project)) == set(identifiers), 'undefined_pbx_reference'
    for path in (ROOT/'ios').rglob('*.swift'):
        assert 'path = '+path.name+';' in project, 'swift_file_missing_from_project'
    scheme=ET.parse(ROOT/'ios/Cubie.xcodeproj/xcshareddata/xcschemes/Cubie.xcscheme')
    assert scheme.getroot().tag == 'Scheme'
    swift_files=list((ROOT/'ios').rglob('*.swift'))
    parsed=False
    try:
        import tree_sitter, tree_sitter_swift
        parser=tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
        for path in swift_files:
            assert not parser.parse(path.read_bytes()).root_node.has_error, 'swift_syntax_error: '+path.name
        parsed=True
    except ImportError:
        pass
    print({'python39_syntax_files':len(python_files),'swift_files_in_project':len(swift_files),
           'swift_parser_available_and_passed':parsed,'scheme_xml':'passed',
           'xcode_typecheck':'not_performed'})


if __name__=='__main__':main()
