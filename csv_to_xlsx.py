#!/usr/bin/env python3
"""
Utility to convert CSV file(s) to an Excel file.
If multiple CSV files are provided, each will be added as a separate sheet.
"""

import sys
from pathlib import Path
import pandas as pd
from openpyxl.utils import get_column_letter


def csv_to_xlsx(input_files, output_file):
    """
    Convert one or more CSV files to a single Excel file.
    Each CSV becomes a separate sheet.
    
    Args:
        input_files: List of CSV file paths
        output_file: Output Excel file path
    """
    # Create Excel writer object
    with pd.ExcelWriter(output_file, engine='openpyxl') as writer:
        for csv_file in input_files:
            csv_path = Path(csv_file)
            
            if not csv_path.exists():
                print(f"Warning: File not found: {csv_file}", file=sys.stderr)
                continue
            
            print(f"Processing: {csv_file}")
            
            # Read CSV file
            try:
                df = pd.read_csv(csv_path)
            except Exception as e:
                print(f"Error reading {csv_file}: {e}", file=sys.stderr)
                continue
            
            # Use filename (without extension) as sheet name
            sheet_name = csv_path.stem
            
            # Excel sheet names have a 31 character limit
            if len(sheet_name) > 31:
                sheet_name = sheet_name[:31]
            
            # Remove invalid characters from sheet name
            invalid_chars = ['[', ']', '*', '?', ':', '/', '\\']
            for char in invalid_chars:
                sheet_name = sheet_name.replace(char, '_')
            
            # Write to Excel
            df.to_excel(writer, sheet_name=sheet_name, index=False)
            
            # Auto-adjust column widths
            worksheet = writer.sheets[sheet_name]
            for i, col in enumerate(df.columns):
                # Find maximum length in column
                max_len = max(
                    df[col].astype(str).apply(len).max(),
                    len(str(col))
                )
                # Set column width (add some padding)
                worksheet.column_dimensions[get_column_letter(i + 1)].width = min(max_len + 2, 50)
    
    print(f"\nExcel file saved to: {output_file}")


def main():
    if len(sys.argv) < 3:
        print("Usage: python csv_to_xlsx.py <output.xlsx> <input1.csv> [input2.csv ...]")
        print("\nExample:")
        print("  python csv_to_xlsx.py output.xlsx data1.csv data2.csv data3.csv")
        print("\nEach CSV file will be added as a separate sheet in the Excel file.")
        sys.exit(1)
    
    output_file = sys.argv[1]
    input_files = sys.argv[2:]
    
    if not output_file.endswith('.xlsx'):
        output_file += '.xlsx'
    
    csv_to_xlsx(input_files, output_file)


if __name__ == '__main__':
    main()
