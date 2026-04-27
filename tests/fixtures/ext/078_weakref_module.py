# weakref module

import weakref

class MyObj:
    def __init__(self, name):
        self.name = name
    def __repr__(self):
        return f'MyObj({self.name!r})'

# Basic weakref
obj = MyObj('test')
ref = weakref.ref(obj)
print(ref() is obj)                                # True
print(ref().name)                                  # test

# WeakValueDictionary
wvd = weakref.WeakValueDictionary()
obj2 = MyObj('bar')
wvd['key'] = obj2
print(wvd['key'].name)                             # bar

# WeakKeyDictionary
wkd = weakref.WeakKeyDictionary()
obj3 = MyObj('baz')
wkd[obj3] = 42
print(wkd[obj3])                                   # 42

# proxy
obj4 = MyObj('qux')
prox = weakref.proxy(obj4)
print(prox.name)                                   # qux
print(type(prox).__name__ != 'MyObj')              # True (it's a proxy type)

# ref with no callback - two refs to same object may be same
obj5 = MyObj('count')
r1 = weakref.ref(obj5)
r2 = weakref.ref(obj5)
print(r1() is obj5)                                # True
print(r2() is obj5)                                # True

# Finalize
called = []
def on_fin():
    called.append('done')

obj6 = MyObj('fin')
fin = weakref.finalize(obj6, on_fin)
print(fin.alive)                                   # True
fin()
print(called)                                      # ['done']
print(fin.alive)                                   # False

print('done')
