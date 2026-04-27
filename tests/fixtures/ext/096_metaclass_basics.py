# class features: __init_subclass__, class methods, __new__

# __init_subclass__
class Plugin:
    _registry = []

    def __init_subclass__(cls, **kwargs):
        pass
        Plugin._registry.append(cls.__name__)

class PluginA(Plugin):
    pass

class PluginB(Plugin):
    pass

class PluginC(Plugin):
    pass

print(sorted(Plugin._registry))                   # ['PluginA', 'PluginB', 'PluginC']

# __init_subclass__ with keyword args
class Tagged:
    _tags = {}

    def __init_subclass__(cls, tag=None, **kwargs):
        pass
        if tag is not None:
            Tagged._tags[cls.__name__] = tag

class FastAlgo(Tagged, tag='fast'):
    pass

class SlowAlgo(Tagged, tag='slow'):
    pass

print(Tagged._tags)                                # {'FastAlgo': 'fast', 'SlowAlgo': 'slow'}

# __class_getitem__ for generic-like notation
class TypedList:
    def __class_getitem__(cls, item):
        return f'{cls.__name__}[{item.__name__}]'

print(TypedList[int])                              # TypedList[int]
print(TypedList[str])                              # TypedList[str]

# Class with class variables and instance variables
class Counter:
    count = 0

    def __init__(self):
        Counter.count += 1
        self.id = Counter.count

c1 = Counter()
c2 = Counter()
c3 = Counter()
print(Counter.count)                               # 3
print(c1.id, c2.id, c3.id)                       # 1 2 3

print('done')
