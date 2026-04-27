# copy module

import copy

# Shallow copy of list
orig = [1, [2, 3], 4]
shallow = copy.copy(orig)
shallow[0] = 99
shallow[1].append(4)  # modifies inner list
print(orig)                                         # [1, [2, 3, 4], 4]
print(shallow)                                      # [99, [2, 3, 4], 4]

# Deep copy of list
orig2 = [1, [2, 3], 4]
deep = copy.deepcopy(orig2)
deep[0] = 99
deep[1].append(4)  # doesn't modify inner list
print(orig2)                                        # [1, [2, 3], 4]
print(deep)                                         # [99, [2, 3, 4], 4]

# Shallow copy of dict
d = {'a': [1, 2], 'b': 3}
dc = copy.copy(d)
dc['a'].append(3)
dc['b'] = 99
print(d)                                            # {'a': [1, 2, 3], 'b': 3}
print(dc)                                           # {'a': [1, 2, 3], 'b': 99}

# Deep copy of dict
d2 = {'a': [1, 2], 'b': 3}
dc2 = copy.deepcopy(d2)
dc2['a'].append(3)
print(d2)                                           # {'a': [1, 2], 'b': 3}
print(dc2)                                          # {'a': [1, 2, 3], 'b': 3}

# Deep copy of nested object
class Node:
    def __init__(self, val, children=None):
        self.val = val
        self.children = children or []

tree = Node(1, [Node(2), Node(3, [Node(4)])])
tree_copy = copy.deepcopy(tree)
tree.children[0].val = 99
print(tree.children[0].val)                        # 99
print(tree_copy.children[0].val)                   # 2 (independent)

# __copy__ dunder
class MyList:
    def __init__(self, data):
        self.data = list(data)
    def __copy__(self):
        return MyList(self.data[:])

ml = MyList([1, 2, 3])
ml2 = copy.copy(ml)
ml2.data.append(4)
print(ml.data)                                      # [1, 2, 3]
print(ml2.data)                                     # [1, 2, 3, 4]

print('done')
