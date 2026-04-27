import xml.etree.ElementTree as ET

# Create elements
root = ET.Element('root')
child1 = ET.SubElement(root, 'child', attrib={'id': '1'})
child1.text = 'Hello'
child2 = ET.SubElement(root, 'child', attrib={'id': '2'})
child2.text = 'World'

# Basic properties
print(root.tag)                                        # root
print(len(root))                                       # 2
print(child1.text)                                     # Hello
print(child1.get('id'))                                # 1

# Iteration
for child in root:
    print(child.tag, child.text)                       # child Hello / child World

# find / findall
found = root.find('child')
print(found is not None)                               # True
print(found.text)                                      # Hello

all_children = root.findall('child')
print(len(all_children))                               # 2

# tostring
xml_str = ET.tostring(root, encoding='unicode')
print('<root>' in xml_str)                             # True
print('<child' in xml_str)                             # True

# fromstring / parse
xml_text = '<data><item id="1">foo</item><item id="2">bar</item></data>'
tree = ET.fromstring(xml_text)
print(tree.tag)                                        # data
items = tree.findall('item')
print(len(items))                                      # 2
print(items[0].text)                                   # foo
print(items[0].get('id'))                              # 1

# Element.set and attrib
e = ET.Element('test')
e.set('key', 'value')
print(e.get('key'))                                    # value
print(e.attrib)                                        # {'key': 'value'}

# tail
e2 = ET.Element('p')
e2.text = 'hello'
e2.tail = ' world'
print(e2.text)                                         # hello
print(e2.tail)                                         # world

print('done')
