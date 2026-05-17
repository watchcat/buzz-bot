"""Static multilingual stop-word set for KeyBERT topic extraction.

Conservative: function words / pronouns / prepositions / conjunctions /
auxiliaries only — never words that could be a standalone topic. Vendored
(no NLTK dependency). Tunable later; goal is removing dominant filler, not
perfection. Used by handler.extract_topics via CountVectorizer(stop_words=...).
"""

# NOTE: only tokens >=2 chars — sklearn's default token_pattern (\b\w\w+\b)
# never tokenizes single-char words, so listing them is a dead no-op AND
# triggers a "stop_words inconsistent" UserWarning. Keep this invariant.
_EN = """
the an and or but if of at by for with about against between into through
during before after to from up down in out on off over under is are was were
be been being have has had do does did this that these those it its as so than
then too very can will just not no you he she we they my your our their me
him her us them what which who how when where why all any both each more most
other some such only own same here there
""".split()

_RU = """
во не что он на со как то все она так его но да ты же вы за бы по
только её мне было вот от меня ещё нет из ему теперь был до вас уже или ни
быть него опять уж вам ведь там потом себя ничего ей они тут где есть надо ней
для мы тебя их чем была сам чтоб без чего раз тоже себе под будет тогда кто
этот того потому этого какой ним здесь этом один мой тем чтобы неё сейчас были
куда зачем всех можно при два об другой после над больше тот через эти нас про
всего них эту моя свою этой перед том такой им более всю между это
""".split()

_NL = """
de het een en van te dat die in is op aan met als voor had er maar om hem dan
zou of wat mijn men dit zo door over ze zich bij ook tot je mij uit der daar
haar naar heb hoe heeft hebben deze want nog zal me zij nu geen omdat iets
worden toch al waren veel meer doen toen moet ben zonder kan hun dus alles
onder ja eens hier wie werd altijd wordt kunnen ons zelf tegen na wil kon niets
uw iemand andere ik
""".split()

STOPWORDS: frozenset[str] = frozenset(_EN + _RU + _NL)
