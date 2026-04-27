import ast

# literal_eval: safe evaluation of Python literals
print(ast.literal_eval('42'))
print(ast.literal_eval('[1, 2, 3]'))
print(ast.literal_eval('{"a": 1}'))
print(ast.literal_eval('True'))
print(ast.literal_eval('None'))
print(ast.literal_eval('(1, 2)'))

# parse returns a Module node
tree = ast.parse('x = 1')
print(type(tree).__name__)
print(tree.body[0].__class__.__name__)

# get_docstring extracts the first string literal in a function body
src = '''def foo():
    "doc"
    pass
'''
tree2 = ast.parse(src)
fn = tree2.body[0]
print(ast.get_docstring(fn))
