import pathlib
import zipfile

out = pathlib.Path(__file__).resolve().parents[1] / 'work/tests'
out.mkdir(parents=True, exist_ok=True)
main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
with zipfile.ZipFile(out / 'schedule.xlsx', 'w') as z:
    z.writestr('xl/workbook.xml', f'<workbook xmlns="{main}" xmlns:r="{rel}"><sheets><sheet name="10" r:id="rId7"/><sheet name="1月" r:id="rId2"/><sheet name="2" r:id="rId3"/></sheets></workbook>')
    z.writestr('xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId7" Target="worksheets/oct.xml"/><Relationship Id="rId2" Target="/xl/worksheets/jan.xml"/><Relationship Id="rId3" Target="worksheets/feb.xml"/></Relationships>')
    z.writestr('xl/sharedStrings.xml', f'<sst xmlns="{main}"><si><r><t>完成</t></r><r><t>练习</t></r></si><si><t>  重复事项  </t></si></sst>')
    z.writestr('xl/worksheets/oct.xml', f'<worksheet xmlns="{main}"><sheetData><row r="1"><c r="A1"><v>19</v></c><c r="B1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c><c r="D1" t="s"><v>1</v></c><c r="E1" t="inlineStr"><is><t>内联 &amp; 文本</t></is></c></row><row r="2"><c r="A2"><v>20</v></c></row><row r="3"><c r="A3"><v>32</v></c><c r="B3" t="inlineStr"><is><t>不应出现</t></is></c></row></sheetData></worksheet>')
    z.writestr('xl/worksheets/jan.xml', f'<worksheet xmlns="{main}"><sheetData><row r="1"><c r="A1"><v>1</v></c><c r="B1" t="inlineStr"><is><t>新年计划</t></is></c></row></sheetData></worksheet>')
    z.writestr('xl/worksheets/feb.xml', f'<worksheet xmlns="{main}"><sheetData><row r="1"><c r="A1"><v>29</v></c><c r="B1" t="inlineStr"><is><t>闰日</t></is></c></row></sheetData></worksheet>')
with zipfile.ZipFile(out / 'inline-only.xlsx', 'w') as z:
    z.writestr('xl/workbook.xml', f'<workbook xmlns="{main}" xmlns:r="{rel}"><sheets><sheet name="10" r:id="rId1"/></sheets></workbook>')
    z.writestr('xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>')
    z.writestr('xl/worksheets/sheet1.xml', f'<worksheet xmlns="{main}"><sheetData><row r="1"><c r="A1"><v>19</v></c><c r="B1" t="inlineStr"><is><t>无需共享字符串</t></is></c></row></sheetData></worksheet>')
(out / 'bad.xlsx').write_text('not a workbook')
with zipfile.ZipFile(out / 'reminders.xlsx', 'w') as z:
    z.writestr('xl/workbook.xml', f'<workbook xmlns="{main}" xmlns:r="{rel}"><sheets><sheet name="10" r:id="rId1"/></sheets></workbook>')
    z.writestr('xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>')
    cases = [
        [('B', '示例任务A'), ('C', '21:00')],
        [('B', '读书 9：05')],
        [('B', '散步'), ('D', '21:00')],
        [('B', '散步'), ('C', '24:00')],
        [('B', '21:00'), ('C', '22:00')],
        [('Z', '练习'), ('AA', '8:30')],
    ]
    rows = []
    for index, cells in enumerate(cases, 1):
        row = f'<row r="{index}"><c r="A{index}"><v>{index}</v></c>'
        row += ''.join(f'<c r="{column}{index}" t="inlineStr"><is><t>{value}</t></is></c>' for column, value in cells)
        rows.append(row + '</row>')
    z.writestr('xl/worksheets/sheet1.xml', f'<worksheet xmlns="{main}"><sheetData>{"".join(rows)}</sheetData></worksheet>')
# A real OOXML style/relationship fixture for surgical completion writes.
with zipfile.ZipFile(out / 'writeback.xlsx', 'w') as z:
    z.writestr('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>')
    z.writestr('_rels/.rels', f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{rel}/officeDocument" Target="xl/workbook.xml"/></Relationships>')
    z.writestr('xl/workbook.xml', f'<workbook xmlns="{main}" xmlns:r="{rel}"><sheets><sheet name="10" sheetId="1" r:id="rId1"/></sheets></workbook>')
    z.writestr('xl/_rels/workbook.xml.rels', f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{rel}/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="{rel}/styles" Target="styles.xml"/><Relationship Id="rId3" Type="{rel}/sharedStrings" Target="sharedStrings.xml"/></Relationships>')
    z.writestr('xl/styles.xml', f'<styleSheet xmlns="{main}"><fonts count="2"><font><b/><sz val="12"/><color rgb="FF123456"/><name val="Arial"/></font><font><strike/><sz val="12"/><name val="Arial"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" horizontal="center"/></xf><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>')
    z.writestr('xl/sharedStrings.xml', f'<sst xmlns="{main}" count="2" uniqueCount="1"><si><r><rPr><b/><color rgb="FF008800"/></rPr><t>示例</t></r><r><rPr><strike val="0"/></rPr><t>任务A</t></r></si></sst>')
    z.writestr('xl/worksheets/sheet1.xml', f'<worksheet xmlns="{main}" xmlns:r="{rel}"><dimension ref="A1:H1"/><cols><col min="2" max="8" width="20" customWidth="1"/></cols><sheetData><row r="1" ht="30" customHeight="1"><c r="A1"><v>19</v></c><c r="B1" s="1" t="s"><v>0</v></c><c r="C1" t="inlineStr"><is><t>21:00</t></is></c><c r="D1" s="1" t="s"><v>0</v></c><c r="E1" s="2" t="inlineStr"><is><r><rPr><b/><strike val="0"/></rPr><t>内联</t></r><r><t>事项</t></r></is></c><c r="F1"><f>1+1</f><v>2</v></c><c r="G1" s="2" t="inlineStr"><is><t>已有删除线</t></is></c><c r="H1" t="inlineStr"><is><t>普通事项</t></is></c></row></sheetData><conditionalFormatting sqref="F1"><cfRule type="expression" priority="1"><formula>F1&gt;0</formula></cfRule></conditionalFormatting></worksheet>')
    z.writestr('docProps/custom.xml', '<unchanged>保留原始内容</unchanged>')
    z.writestr('xl/media/preserved.bin', bytes(range(256)))
