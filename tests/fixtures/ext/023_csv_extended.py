import csv
import io

# Basic writer/reader via StringIO
buf = io.StringIO()
writer = csv.writer(buf)
writer.writerow(['name', 'age', 'city'])
writer.writerow(['Alice', 30, 'NYC'])
writer.writerow(['Bob', 25, 'LA'])
writer.writerows([['Carol', 35, 'Chicago'], ['Dave', 28, 'Boston']])

buf.seek(0)
reader = csv.reader(buf)
rows = list(reader)
print(len(rows))                                       # 5
print(rows[0])                                         # ['name', 'age', 'city']
print(rows[1][0])                                      # Alice

# DictWriter / DictReader
buf2 = io.StringIO()
fields = ['x', 'y']
dw = csv.DictWriter(buf2, fieldnames=fields)
dw.writeheader()
dw.writerow({'x': 1, 'y': 2})
dw.writerow({'x': 3, 'y': 4})

buf2.seek(0)
dr = csv.DictReader(buf2)
drows = list(dr)
print(len(drows))                                      # 2
print(drows[0]['x'])                                   # 1

# Custom delimiter
buf3 = io.StringIO()
w3 = csv.writer(buf3, delimiter='|')
w3.writerow(['a', 'b', 'c'])
buf3.seek(0)
r3 = csv.reader(buf3, delimiter='|')
print(list(r3)[0])                                     # ['a', 'b', 'c']

# Quoting
buf4 = io.StringIO()
w4 = csv.writer(buf4)
w4.writerow(['hello, world', 'says "hi"', 'normal'])
buf4.seek(0)
r4 = csv.reader(buf4)
row4 = list(r4)[0]
print(row4[0])                                         # hello, world
print(row4[1])                                         # says "hi"

print('done')
