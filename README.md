# util

Personal shell and Python utilities for document conversion, AWS tagging, macOS helpers, and network diagnostics.

**Status and stance:** personal tools published as-is, for my own use. Pull requests and issues are not expected, there is no support, and maintenance is occasional. Use at your own risk, and read a script before running it against your own accounts. There are no automated tests; the AWS scripts have read-only or dry-run modes, which is how they are checked (see each section).

## Python utilities

Install dependencies:

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Markdown to Word (`md_to_docx.py`)

Converts one or more markdown files into a single Word document with page breaks between files.

Limits: nested lists are flattened to one level, links are shown as underlined text followed by the URL (not live hyperlinks), and only the basic block types (headings, paragraphs, lists, code, quotes, tables) are converted.

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

Scans AWS resources for missing or malformed cost-allocation tags (`Application`, `Environment`). **Read-only by default**: it only modifies resources when you pass `-t`/`--tag`, which walks through each resource and asks for `app,env` before writing. Add `-n`/`--dry-run` to `-t` to rehearse the prompts without changing anything. Other flags: `-r` region, `-s` services, `-c` CSV file, `-o table|csv`, `-a` include tagged, `-j` parallel jobs, `-q` quiet (see `-h`).

Requires: AWS CLI configured with read access (`-t` also needs tagging permissions). Default region is `us-west-2` (or `$AWS_REGION`). The CSV output contains your account ID, resource names and ARNs: keep it out of git (see `examples/` for the format, with invented values).

```bash
./audit_aws_tags.sh
./audit_aws_tags.sh -c missing-tags.csv
./audit_aws_tags.sh -s ec2-instance,rds-instance,s3,lambda
./audit_aws_tags.sh -t -n              # rehearse interactive tagging
```

Limit: tagging an S3 bucket replaces its whole tag set, so the script re-reads the existing tags first and refuses to write if they cannot be read.

### AWS resource tagger (`tag_aws_resources.sh`)

Discovers and tags AWS resources for an application repo. Supports prefix auto-detection and a `.aws-tagger.yml` override file. **Dry run by default**: it prints the tags it would add and writes nothing unless you pass `--apply`.

Requires: AWS CLI configured with tagging permissions. Default region is `us-west-2` (or `$AWS_REGION`).

```bash
./tag_aws_resources.sh -f              # auto-detect from current directory; preview only
./tag_aws_resources.sh -f --apply      # write the tags
./tag_aws_resources.sh myapp prod      # one app and environment; preview only
```

Limits: resource names are matched by prefix and the environment comes from a `-prod`/`-staging`/`-dev` suffix; names with no suffix are treated as `prod`. Read the preview before using `--apply`. NAT gateways must be tagged by hand.

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

Pings the local gateway and 8.8.8.8 and resolves a DNS name every 30 seconds (set `NETCHECK_INTERVAL=seconds` to change it), logging results with timestamps.

```bash
./netcheck.sh              # logs to netcheck.log
./netcheck.sh my-check.log
NETCHECK_INTERVAL=10 ./netcheck.sh
```

## Requirements

| Tool | Dependencies |
|------|-------------|
| Python scripts | Python 3.9+, see `requirements.txt` |
| AWS scripts | AWS CLI, bash |
| `grep-docs.sh` | `pdfgrep`, `docx2txt` (Homebrew) |
| `browser-manager.sh` | macOS (bash 3.2 compatible) |
| `netcheck.sh` | macOS (`ping`, `route`, `dig`) |

## License

MIT, copyright Chintan Shah — see [LICENSE](LICENSE).
