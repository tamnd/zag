# property descriptor extended

class Temperature:
    def __init__(self, celsius=0):
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

    @fahrenheit.setter
    def fahrenheit(self, value):
        self._celsius = (value - 32) * 5/9

t = Temperature(25)
print(t.celsius)                                   # 25
print(t.fahrenheit)                               # 77.0

t.celsius = 100
print(t.celsius)                                   # 100
print(t.fahrenheit)                               # 212.0

t.fahrenheit = 32
print(round(t.celsius, 1))                       # 0.0

try:
    t.celsius = -300
except ValueError as e:
    print('ValueError raised')                    # ValueError raised

# property with deleter
class CachedProp:
    def __init__(self):
        self._value = None

    @property
    def value(self):
        return self._value

    @value.setter
    def value(self, v):
        self._value = v

    @value.deleter
    def value(self):
        self._value = None

cp = CachedProp()
cp.value = 42
print(cp.value)                                    # 42
del cp.value
print(cp.value)                                    # None

# property as class method
class Circle:
    PI = 3.14159

    def __init__(self, radius):
        self._radius = radius

    @property
    def radius(self):
        return self._radius

    @property
    def area(self):
        return self.PI * self._radius ** 2

    @property
    def circumference(self):
        return 2 * self.PI * self._radius

c = Circle(5)
print(c.radius)                                    # 5
print(round(c.area, 2))                            # 78.54
print(round(c.circumference, 2))                  # 31.42

print('done')
