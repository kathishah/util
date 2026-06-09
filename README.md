# util

Personal shell and Python utilities for document conversion, AWS tagging, macOS helpers, and network diagnostics.

## Python utilities

Install dependencies:

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Markdown to Word (`md_to_docx.py`)

Converts one or more markdown files into a single Word document with page breaks between files.

```bash
python md_to_docx.py report.docx readme.md
python md_to_docx.py combined.docx intro.md chapter1.md chapter2.md
```

### CSV to Excel (`csv_to_xlsx.py`)

Converts one or more CSV files into a single Excel workbook (one sheet per CSV).

```bash
python csv_to_xlsx.py data.xlsx sales.csv
python csv_to_xlsx.py report.xlsx sales.csv inventory.csv customers.csv
```

## Shell utilities

### AWS tag audit (`audit_aws_tags.sh`)

Read-only scan of AWS resources missing required cost-allocation tags. Does not modify any resources.

Requires: AWS CLI configured with read access.

```bash
./audit_aws_tags.sh
./audit_aws_tags.sh -c missing-tags.csv
./audit_aws_tags.sh -s ec2-instance,rds-instance,s3,lambda
```

### AWS resource tagger (`tag_aws_resources.sh`)

Discovers and tags AWS resources for an application repo. Supports dry-run, prefix auto-detection, and a `.aws-tagger.yml` override file.

Requires: AWS CLI configured with tagging permissions.

```bash
./tag_aws_resources.sh -f              # auto-detect from current directory
./tag_aws_resources.sh -f -n           # dry-run
./tag_aws_resources.sh myapp prod
```

### Browser manager (`browser-manager.sh`)

macOS helper to list installed browsers and set the system default.

```bash
./browser-manager.sh
```

### Document grep (`grep-docs.sh`)

Search across PDF and DOCX files in a folder.

Requires: `brew install pdfgrep docx2txt`

```bash
./grep-docs.sh "search term" /path/to/folder
./grep-docs.sh -i "search term" .
```

### Network check (`netcheck.sh`)

Pings the local gateway and 8.8.8.8 every 10 seconds, logging results with timestamps.

```bash
./netcheck.sh              # logs to netcheck.log
./netcheck.sh my-check.log
```

## Requirements

| Tool | Dependencies |
|------|-------------|
| Python scripts | Python 3.7+, see `requirements.txt` |
| AWS scripts | AWS CLI, bash |
| `grep-docs.sh` | `pdfgrep`, `docx2txt` (Homebrew) |
| `browser-manager.sh` | macOS |
| `netcheck.sh` | macOS (`ping`, `route`, `dig`) |

## License

MIT — see [LICENSE](LICENSE).
