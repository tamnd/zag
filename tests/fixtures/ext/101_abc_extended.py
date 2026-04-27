# abc module - abstract methods and polymorphism

from abc import ABC, abstractmethod

class Shape(ABC):
    @abstractmethod
    def area(self) -> float:
        pass

    @abstractmethod
    def perimeter(self) -> float:
        pass

    def describe(self) -> str:
        return f'{self.__class__.__name__}: area={self.area():.2f}'

class Circle(Shape):
    def __init__(self, radius):
        self.radius = radius

    def area(self):
        return 3.14159 * self.radius ** 2

    def perimeter(self):
        return 2 * 3.14159 * self.radius

class Rectangle(Shape):
    def __init__(self, w, h):
        self.w = w
        self.h = h

    def area(self):
        return self.w * self.h

    def perimeter(self):
        return 2 * (self.w + self.h)

c = Circle(5)
print(round(c.area(), 2))                          # 78.54
print(round(c.perimeter(), 2))                    # 31.42
print(c.describe())                               # Circle: area=78.54

r = Rectangle(3, 4)
print(r.area())                                    # 12
print(r.perimeter())                              # 14

print(isinstance(c, Shape))                       # True
print(isinstance(r, Shape))                       # True
print(issubclass(Circle, Shape))                  # True

# Abstract property
class Animal(ABC):
    @property
    @abstractmethod
    def sound(self) -> str:
        pass

    def speak(self):
        return f'I say {self.sound}'

class Dog(Animal):
    @property
    def sound(self):
        return 'woof'

class Cat(Animal):
    @property
    def sound(self):
        return 'meow'

d = Dog()
print(d.speak())                                   # I say woof
cat = Cat()
print(cat.speak())                                 # I say meow

# Multiple inheritance with ABC
class Flyable(ABC):
    @abstractmethod
    def fly(self) -> str:
        pass

class Swimmable(ABC):
    @abstractmethod
    def swim(self) -> str:
        pass

class Duck(Flyable, Swimmable):
    def fly(self):
        return 'Duck flying'
    def swim(self):
        return 'Duck swimming'

duck = Duck()
print(duck.fly())                                  # Duck flying
print(duck.swim())                                 # Duck swimming
print(isinstance(duck, Flyable))                  # True
print(isinstance(duck, Swimmable))                # True

print('done')
