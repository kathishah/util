#!/bin/bash
# grep-docs.sh — grep across PDF and DOCX files in a folder
#
# Install dependencies:
#   brew install pdfgrep docx2txt
#
# Usage:
#   ./grep-docs.sh [options] "search term" /path/to/folder
#   ./grep-docs.sh [options] "search term"   # searches current directory
#
# Options:
#   -i    Case-insensitive matching

CASE_FLAG=""
while getopts "i" opt; do
  case $opt in
    i) CASE_FLAG="-i" ;;
  esac
done
shift $((OPTIND - 1))

PATTERN="$1"
FOLDER="${2:-.}"

if [[ -z "$PATTERN" ]]; then
  echo "Usage: $0 [-i] \"search term\" [/path/to/folder]"
  exit 1
fi

echo "Searching for: \"$PATTERN\" in $FOLDER ${CASE_FLAG:+(case-insensitive)}"
echo "────────────────────────────────────────"

# PDFs — pdfgrep natively handles these
echo ""
echo "📄 PDFs:"
pdfgrep -n $CASE_FLAG "$PATTERN" "$FOLDER"/*.pdf 2>/dev/null || echo "  (no PDF matches)"

# DOCX — convert to text on the fly, then grep
echo ""
echo "📝 DOCX:"
FOUND_DOCX=0
for f in "$FOLDER"/*.docx; do
  [[ -e "$f" ]] || continue
  MATCHES=$(docx2txt "$f" - 2>/dev/null | grep -n $CASE_FLAG "$PATTERN")
  if [[ -n "$MATCHES" ]]; then
    echo "$(basename "$f"):"
    echo "$MATCHES" | sed 's/^/  /'
    FOUND_DOCX=1
  fi
done
[[ $FOUND_DOCX -eq 0 ]] && echo "  (no DOCX matches)"
