"""Reads the club's member spreadsheet and prints the six imported columns as JSON on stdout.

No logic lives here: every rule (duplicates, date formats, clean-up) is in
supabase/functions/_shared/member-import-rules.ts, so the script and the Edge Function agree.
The file is read in place and nothing is written to disk. Usage: python read-members-xlsx.py <file.xlsx>
"""
import datetime
import json
import sys

import openpyxl

COLUMNS = {
    "id_no": "ID NO",
    "display_name": "Display Name",
    "dob": "Date of Birth",
    "mobile": "Mobile Number",
    "email": "Email Address",
    "rfid": "RFID CODE",
}
# Read for the enrich step; missing columns are simply left out.
EXTRA = {
    "last_name": "Lastname",
    "first_name": "Firstname",
    "middle_name": "Middlename",
    "suffix": "Suffix",
    "gender": "Gender",
    "em_name": "Emergency Contact Name",
    "em_rel": "Relationship",
    "em_phone": "Emergency Contact Number",
}


def text(value):
    """A cell as trimmed text; numbers lose a trailing .0 (phone and RFID cells are often numeric)."""
    if value is None:
        return None
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    s = str(value).strip()
    return s or None


def main(path):
    book = openpyxl.load_workbook(path, read_only=True, data_only=True)
    sheet = book[book.sheetnames[0]]
    rows = sheet.iter_rows(values_only=True)
    header = [str(h).strip() if h is not None else "" for h in next(rows)]
    missing = [name for name in COLUMNS.values() if name not in header]
    if missing:
        sys.exit("missing columns: " + ", ".join(missing))
    index = {key: header.index(name) for key, name in COLUMNS.items()}
    extra = {key: header.index(name) for key, name in EXTRA.items() if name in header}
    out = []
    for number, row in enumerate(rows, start=2):
        dob_cell = row[index["dob"]]
        dob = dob_text = None
        if isinstance(dob_cell, (datetime.datetime, datetime.date)):
            dob = dob_cell.date().isoformat() if isinstance(dob_cell, datetime.datetime) else dob_cell.isoformat()
        else:
            dob_text = text(dob_cell)
        out.append({
            "row": number,
            "id_no": text(row[index["id_no"]]),
            "display_name": text(row[index["display_name"]]),
            "dob": dob,
            "dob_text": dob_text,
            "mobile": text(row[index["mobile"]]),
            "email": text(row[index["email"]]),
            "rfid": text(row[index["rfid"]]),
            **{key: text(row[i]) for key, i in extra.items()},
        })
    sys.stdout.reconfigure(encoding="utf-8")
    json.dump(out, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: read-members-xlsx.py <file.xlsx>")
    main(sys.argv[1])
