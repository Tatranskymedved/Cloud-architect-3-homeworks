"""
Convert UCI Online Retail II Excel sheets to CSV files.

Usage:
    python scripts/excel_to_csv.py --input "Online Retail II.xlsx" --output-dir .

Requirements:
    pip install -r scripts/requirements.txt
"""

import argparse
import pathlib
import pandas as pd


def main():
    parser = argparse.ArgumentParser(description="Convert Online Retail II xlsx to CSV.")
    parser.add_argument("--input",      required=True, help="Path to the .xlsx file.")
    parser.add_argument("--output-dir", default=".",   help="Directory for output CSV files.")
    args = parser.parse_args()

    out = pathlib.Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)

    sheet_map = {
        "Year 2009-2010": "retail_2009.csv",
        "Year 2010-2011": "retail_2010.csv",
    }

    for sheet_name, csv_name in sheet_map.items():
        print(f"Reading sheet '{sheet_name}' ...")
        df = pd.read_excel(args.input, sheet_name=sheet_name, dtype=str)
        out_path = out / csv_name
        df.to_csv(out_path, index=False)
        print(f"  Written {len(df):,} rows to {out_path}")

    print("Done.")


if __name__ == "__main__":
    main()
