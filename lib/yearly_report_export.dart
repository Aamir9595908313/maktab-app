// Shared PDF / Excel / CSV export for the two "Yearly Collection" reports
// (Monthly Members and Sadqa Peti). Rows are plain lists: String cells are
// text, num cells are numbers (so Excel can sum them).
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as xl;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

class YearlyReportData {
  final String title; // e.g. "Sadqa Peti - Yearly Collection 2026"
  final String fileBase; // e.g. "sadqa_peti_collection_2026"
  final List<String> headers;
  final List<List<Object>> rows;
  final List<Object> totalRow;
  /// Number of leading text columns (the rest are amounts).
  final int textCols;
  YearlyReportData({required this.title, required this.fileBase, required this.headers, required this.rows, required this.totalRow, required this.textCols});

  String _s(Object v) => v is num ? v.toStringAsFixed(0) : '$v';
  String _dash(Object v) => v is num ? (v == 0 ? '-' : v.toStringAsFixed(0)) : '$v';

  Future<void> sharePdf() async {
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(20),
      build: (ctx) => [
        pw.Text(title, style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
        pw.Text('Faiz-E-Raza Group Mehkar - Maktab-E-Tajushshriah', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        pw.SizedBox(height: 8),
        pw.TableHelper.fromTextArray(
          headers: headers,
          data: [
            for (final r in rows) [for (final v in r) _dash(v)],
            [for (final v in totalRow) _dash(v)],
          ],
          headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 7.5),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.green100),
          cellAlignments: {for (var i = textCols; i < headers.length; i++) i: pw.Alignment.centerRight},
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          oddRowDecoration: null,
        ),
      ],
    ));
    await Printing.sharePdf(bytes: await doc.save(), filename: '$fileBase.pdf');
  }

  Future<void> shareExcel() async {
    final excel = xl.Excel.createExcel();
    const sheetName = 'Report';
    final sheet = excel[sheetName];
    for (final n in List<String>.from(excel.sheets.keys)) {
      if (n != sheetName) excel.delete(n);
    }
    final head = xl.CellStyle(bold: true, backgroundColorHex: xl.ExcelColor.fromHexString('#D9E8D4'), horizontalAlign: xl.HorizontalAlign.Center);
    final tot = xl.CellStyle(bold: true, backgroundColorHex: xl.ExcelColor.fromHexString('#C8E6C9'));
    void put(int c, int r, Object v, {xl.CellStyle? style}) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
      cell.value = v is num ? xl.IntCellValue(v.round()) : xl.TextCellValue('$v');
      if (style != null) cell.cellStyle = style;
    }

    put(0, 0, title, style: xl.CellStyle(bold: true, fontSize: 14));
    put(0, 1, 'Faiz-E-Raza Group Mehkar - Maktab-E-Tajushshriah');
    var r = 3;
    for (var c = 0; c < headers.length; c++) {
      put(c, r, headers[c], style: head);
    }
    r++;
    for (final row in rows) {
      for (var c = 0; c < row.length; c++) {
        put(c, r, row[c]);
      }
      r++;
    }
    for (var c = 0; c < totalRow.length; c++) {
      put(c, r, totalRow[c], style: tot);
    }
    for (var c = 0; c < headers.length; c++) {
      sheet.setColumnWidth(c, c < textCols ? 22 : 9);
    }
    final bytes = excel.encode();
    if (bytes == null) throw Exception('encode failed');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileBase.xlsx');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path)], text: title);
  }

  Future<void> shareCsv() async {
    final data = <List<String>>[
      headers,
      for (final r in rows) [for (final v in r) _s(v)],
      [for (final v in totalRow) _s(v)],
    ];
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileBase.csv');
    await file.writeAsString(const ListToCsvConverter().convert(data));
    await Share.shareXFiles([XFile(file.path)], text: title);
  }
}
