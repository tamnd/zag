# csv module

import csv
import io

# Writer
output = io.StringIO()
writer = csv.writer(output)
writer.writerow(['Name', 'Age', 'City'])
writer.writerow(['Alice', 30, 'NYC'])
writer.writerow(['Bob', 25, 'LA'])
writer.writerows([['Charlie', 35, 'Chicago'], ['Diana', 28, 'Houston']])
content = output.getvalue()
print(content)

# Reader
data = 'Name,Age,City\nAlice,30,NYC\nBob,25,LA\n'
reader = csv.reader(io.StringIO(data))
for row in reader:
    print(row)

# DictWriter
output2 = io.StringIO()
fieldnames = ['name', 'score']
dw = csv.DictWriter(output2, fieldnames=fieldnames)
dw.writeheader()
dw.writerow({'name': 'Alice', 'score': 95})
dw.writerow({'name': 'Bob', 'score': 87})
print(output2.getvalue())

# DictReader
data2 = 'name,score\nAlice,95\nBob,87\n'
dr = csv.DictReader(io.StringIO(data2))
for row in dr:
    print(row['name'], row['score'])

# Custom delimiter
output3 = io.StringIO()
writer2 = csv.writer(output3, delimiter=';')
writer2.writerow(['a', 'b', 'c'])
print(output3.getvalue().strip())                   # a;b;c

# Quoting special chars (minimal quoting)
output4 = io.StringIO()
writer3 = csv.writer(output4)
writer3.writerow(['hello', 'world, test', '42'])
print(output4.getvalue().strip())                   # hello,"world, test",42

# csv.QUOTE constants
print(csv.QUOTE_ALL)                               # 1
print(csv.QUOTE_MINIMAL)                           # 0

print('done')
