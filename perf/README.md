# PC1: Practica Calificada #1
**course:** Programación III  
**unit:** 1 y 2  
**cmake project:** prog3_pc1_teo3_v2023_2
## Indicaciones Específicas
- El tiempo límite para la evaluación es 100 minutos.
- Cada pregunta deberá ser respondida en un archivo fuente (`.cpp`) y un archivo cabecera (`.h`) con el número de la pregunta:
    - `P1.cpp, P1.h`
    - `P2.cpp, P2.h`
- Deberás subir estos archivos directamente a [www.gradescope.com](https://www.gradescope.com) o se puede crear un `.zip` que contenga todos ellos y subirlo.


## Question #1 - clases, punteros y sobrecarga de operadores y template de clases (14 points)

El Sudoku es un juego de lógica en el que se rellena un tablero dividido en subgrupos con números o caracteres únicos en cada fila, columna y subgrupo. Desarrollar un tablero `table` de Sudoku genérico dentro del namespace `sudoku` que pueda adaptarse a diferentes tamaños y tipos de datos, y que utilice memoria dinámica para su almacenamiento.

Construir un tablero Sudoku genérico, permitiendo diferentes tamaños basados en el parámetro de template no tipo `sub_groups` que representa la dimension de cada sub grupo y el parametro `T` que representa el tipo de dato que almacerara el tablero (por ejemplo, int o char).

El tablero debe ser almacenado en memoria dinámica. Implementar los constructores adecuados para inicializar y copiar tableros, así como un destructor para liberar la memoria correctamente.

Para facilitar la impresión del tablero con un formato adecuado sobrecargar el operador `<<`. También implemente las sobrecargas del operador () para acceder y modificar celdas individuales, similar a lo desarrollado en el ejercicio matriz.

Proporcionar el método `is_valid` que valide si la disposición actual del tablero respeta las reglas del Sudoku retornando `true` si todas las siguentes reglas se cumplen:
  - Cada fila tiene números o caracteres únicos que suman el total esperado.
  - Cada columna tiene números o caracteres únicos que suman el total esperado.
  - Cada subgrupo tiene números o caracteres únicos que suman el total esperado.

Consejos:
- Recuerde gestionar la memoria de manera eficiente utilizando `new` para la asignación y `delete[]` para la liberación, evitando así potenciales fugas de memoria.
- Para el cálculo del total esperado de cada regla, mencionada en el parrafo anterior, utilizar la siguiente formula:
  ```
    [total esperado] = ([valor inicial] + [valor final]) * [cantidad de terminos] / 2
  
    ejemplo:
      si el rango de valores validos del sudoku esta entre 1 y 9
      [total esperado] = (1 + 9) * 9 / 2 = 45
  
      si el rango de valores validos del sudoku esta entre 'A'(65) y 'D'(68)
      [total esperado] = (65 + 68) * 4 / 2 = 266
  ```

**Use Case #1:**
```cpp
  sudoku::table<int, 3> st = {
    1, 2, 3, 1, 2, 3, 1, 2, 3,
    4, 5, 6, 4, 5, 6, 4, 5, 6,
    7, 8, 9, 7, 8, 9, 7, 8, 9,
    1, 2, 3, 1, 2, 3, 1, 2, 3,
    4, 5, 6, 4, 5, 6, 4, 5, 6,
    7, 8, 9, 7, 8, 9, 7, 8, 9,
    1, 2, 3, 1, 2, 3, 1, 2, 3,
    4, 5, 6, 4, 5, 6, 4, 5, 6,
    7, 8, 9, 7, 8, 9, 7, 8, 9
  };
  cout << st;
```

**Use Case #2:**
```cpp
  sudoku::table<int, 3> st = {
    1, 2, 3, 1, 2, 3, 1, 2, 3,
    4, 5, 6, 4, 5, 6, 4, 5, 6,
    7, 8, 9, 7, 8, 9, 7, 8, 9,
    1, 2, 3, 1, 2, 3, 1, 2, 3,
    4, 5, 6, 4, 5, 6, 4, 5, 6,
    7, 8, 9, 7, 8, 9, 7, 8, 9,
    1, 2, 3, 1, 2, 3, 1, 2, 3,
    4, 5, 6, 4, 5, 6, 4, 5, 6,
    7, 8, 9, 7, 8, 9, 7, 8, 9
  };
  cout << boolalpha << st.is_valid() << endl;

  sudoku::table<int, 3> st2 = {
    1, 2, 3, 4, 5, 6, 7, 8, 9,
    4, 5, 6, 7, 8, 9, 1, 2, 3,
    7, 8, 9, 1, 2, 3, 4, 5, 6,
    2, 3, 4, 5, 6, 7, 8, 9, 1,
    5, 6, 7, 8, 9, 1, 2, 3, 4,
    8, 9, 1, 2, 3, 4, 5, 6, 7,
    3, 4, 5, 6, 7, 8, 9, 1, 2,
    6, 7, 8, 9, 1, 2, 3, 4, 5,
    9, 1, 2, 3, 4, 5, 6, 7, 8
  };
  cout << boolalpha << st2.is_valid() << endl;
```

**Use Case #3:**

```cpp
  sudoku::table<int, 2> st = {
    1, 2, 3, 4,
    3, 4, 1, 2,
    2, 3, 4, 1,
    4, 1, 2, 3};
  cout << boolalpha << st.is_valid() << endl;
  auto st2 = st;
  sudoku::table<int, 2> st3;
  st3 = st2;
  st2(0, 0) = 4;
  cout << boolalpha << st.is_valid() << endl;
  cout << boolalpha << st2.is_valid() << endl;
  cout << boolalpha << st3.is_valid() << endl;
```

**Use Case #4:**

```cpp
  sudoku::table<char, 2> st = {
    'A', 'B', 'C', 'D',
    'C', 'D', 'A', 'B',
    'B', 'C', 'D', 'A',
    'D', 'A', 'B', 'C',};
  cout << boolalpha << st.is_valid() << endl;
  st(0,0) = 'D';
  cout << boolalpha << st.is_valid() << endl;
  for (int i = 0; i < st.cells(); ++i){
    for (int j = 0; j < st.cells(); ++j)
      cout << setw(3) << st(i, j);
    cout << endl;
  }
```

## Question #2 - template de función (6 points)

Desarrolla una función llamada `find_median_of_concatenated` que cumpla con las siguientes características:

- La función debe ser un template que pueda trabajar con diferentes tipos de contenedores.
- Utiliza `variadic templates` para que la función acepte un número variable de contenedores como argumentos.
- La función debe concatenar los contenidos de todos los contenedores proporcionados.
- Una vez que todos los elementos están ordenados en un único contenedor, la función deberá encontrar la mediana de los valores y retornas en un `std::pair<T, ContainerResult<T>>` la media y el contenedor ordenando.
- Si el número total de elementos es impar, retorna el elemento central. Si es par, retorna el promedio de los dos elementos centrales.
- Por defecto, el contenedor utilizado para concatenar y ordenar será de tipo std::vector. Sin embargo, debe ser posible especificar un tipo de contenedor diferente.

**Use Case #1:**
```cpp
  std::vector<int> v1 = {2, 3, 5};
  std::vector<int> v2 = {10, 15, 20, 25};
  std::vector<int> v3 = {0, 1};
  
  auto [median, ordered_data] = find_median_of_concatenated(v1, v2, v3);
  std::cout << median << std::endl;
  for (const auto& item: ordered_data) std::cout << item << " ";
  std::cout << std::endl;
```

**Use Case #2:**
```cpp
  std::vector<int> v1 = {2, 3, 4, 9};
  std::list<int> l1 = {10, 15, 20, 25};
  std::deque<int> d1 = {0, 1};
  
  auto [median, ordered_data] = find_median_of_concatenated(v1, l1, d1);
  std::vector<int> v2 = ordered_data;
  std::cout << median << std::endl;
  for (const auto& item: ordered_data) std::cout << item << " ";
  std::cout << std::endl;
```

**Use Case #3:**
```cpp
  std::vector<double> v1 = {2, 3, 4, 9};
  std::list<double> l1 = {10, 15, 20, 25};
  std::deque<double> d1 = {0, 1};
  
  auto [median, ordered_data] = find_median_of_concatenated<std::deque>(v1, l1, d1);
  deque<double> dr = ordered_data;
  std::cout << median << std::endl;
  for (const auto& item: ordered_data) std::cout << item << " ";
  std::cout << std::endl;
```

**Use Case #4:**
```cpp
  std::deque<float> d1 = {2};
  
  auto [median, ordered_data] = find_median_of_concatenated(d1);
  std::cout << median << std::endl;
  for (const auto& item: ordered_data) std::cout << item << " ";
  std::cout << std::endl;
```

