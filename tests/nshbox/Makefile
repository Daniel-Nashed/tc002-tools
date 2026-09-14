TARGET  = nshbox_tests

CXX     = g++
CXXFLAGS = -std=c++17 -Wall -Wextra -O0 -g

SRC     = $(wildcard *.cpp)
OBJ     = $(SRC:.cpp=.o)

all: $(TARGET)

$(TARGET): $(OBJ)
	$(CXX) $(CXXFLAGS) $(OBJ) -o $@

%.o: %.cpp *.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) *.o

.PHONY: all clean
