/* Минимальный заголовок C-API hunspell для fallback-сборки спелчекера на
 * машинах, где установлен только РАНТАЙМ-пакет hunspell (libhunspell-1.7-0)
 * без dev-пакета (нет системного hunspell/hunspell.h).
 *
 * Объявлены ровно те функции, что использует SpellChecker.cpp. Сигнатуры
 * соответствуют публичному стабильному C-API hunspell (см. оригинальный
 * src/hunspell/hunspell.h). Линкуемся напрямую с libhunspell-1.7.so.0 —
 * символы экспортируются с C-линковкой, поэтому ABI совпадает.
 *
 * Это НЕ legacy-фолбэк формата (см. правило no-legacy) — это обычный приём
 * сборки против рантайм-only библиотеки, эквивалент установки dev-пакета.
 */
#ifndef PARANOIA_HUNSPELL_FALLBACK_H_
#define PARANOIA_HUNSPELL_FALLBACK_H_

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Hunhandle Hunhandle;

Hunhandle *Hunspell_create(const char *affpath, const char *dpath);
Hunhandle *Hunspell_create_key(const char *affpath, const char *dpath, const char *key);
void Hunspell_destroy(Hunhandle *pHunspell);

/* 1 — слово в словаре, 0 — опечатка. */
int Hunspell_spell(Hunhandle *pHunspell, const char *word);

/* Заполняет *slst массивом из n строк-подсказок (владелец — hunspell). */
int Hunspell_suggest(Hunhandle *pHunspell, char ***slst, const char *word);

/* Освобождает список, выданный Hunspell_suggest. */
void Hunspell_free_list(Hunhandle *pHunspell, char ***slst, int n);

#ifdef __cplusplus
}
#endif

#endif /* PARANOIA_HUNSPELL_FALLBACK_H_ */
