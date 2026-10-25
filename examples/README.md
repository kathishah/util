# Examples

`aws_tag_audit.example.csv` shows the shape of the CSV written by
`audit_aws_tags.sh -c FILE`. All values are invented. In the `tags` column the
first value is the `Application` tag and the second is `Environment`; `M`
means the tag is missing.

A real audit file contains your AWS account ID, resource names and ARNs. Keep
real output out of git: `.gitignore` already excludes `aws_resource_tags_*.csv`
and `missing-tags*.csv`, so write audit output to one of those names or to a
folder outside the repository.
