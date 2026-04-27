# Class features: properties, classmethod, staticmethod, __slots__, descriptors

# properties
class Temperature:
    def __init__(self, celsius):
        self._celsius = celsius

    @property
    def celsius(self):
        return self._celsius

    @celsius.setter
    def celsius(self, value):
        if value < -273.15:
            raise ValueError('Temperature below absolute zero')
        self._celsius = value

    @property
    def fahrenheit(self):
        return self._celsius * 9/5 + 32

t = Temperature(100)
print(t.celsius)                                      # 100
print(t.fahrenheit)                                   # 212.0
t.celsius = 0
print(t.fahrenheit)                                   # 32.0

# classmethod and staticmethod
class Counter:
    count = 0

    def __init__(self):
        Counter.count += 1

    @classmethod
    def get_count(cls):
        return cls.count

    @staticmethod
    def reset():
        Counter.count = 0

c1 = Counter()
c2 = Counter()
c3 = Counter()
print(Counter.get_count())                            # 3
Counter.reset()
print(Counter.get_count())                            # 0

# __str__ and __repr__
class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y

    def __str__(self):
        return f'Point({self.x}, {self.y})'

    def __repr__(self):
        return f'Point(x={self.x!r}, y={self.y!r})'

p = Point(1, 2)
print(str(p))                                         # Point(1, 2)
print(repr(p))                                        # Point(x=1, y=2)

# __len__, __getitem__, __contains__
class WordList:
    def __init__(self, words):
        self.words = words

    def __len__(self):
        return len(self.words)

    def __getitem__(self, idx):
        return self.words[idx]

    def __contains__(self, word):
        return word in self.words

wl = WordList(['hello', 'world', 'python'])
print(len(wl))                                        # 3
print(wl[1])                                          # world
print('python' in wl)                                 # True
print('java' in wl)                                   # False

# __iter__
class Range:
    def __init__(self, start, stop):
        self.start = start
        self.stop = stop

    def __iter__(self):
        current = self.start
        while current < self.stop:
            yield current
            current += 1

r = Range(1, 5)
print(list(r))                                        # [1, 2, 3, 4]

print('done')
