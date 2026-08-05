// The corpus the app ships inside its binary, in each language the app speaks.
//
// Every work here is in the public domain and every quotation is from one of them; the
// analysis around those quotations — the ideas, the themes, the edges between them, the gaps
// and the notes — was written for this file. That rule is not a preference. The snapshot this
// seeds is compiled into a binary that goes to the App Store, and anything private that
// entered it could never be taken out again, so no real vault is ever read to build it.
//
// It is a real corpus rather than lorem ipsum because the demo has to survive being poked at:
// a reader who opens an idea expects the works it occurs in, the quotation it rests on, and
// the ideas it argues with. Ten works of nineteenth-century political and moral thought
// disagree with each other enough to make debates that are actually debates.
//
// ── What is translated, and what is not ──────────────────────────────────────
//
// One snapshot is built per interface language, and the app opens the one that matches the
// phone. What gets translated is everything a researcher would have *written*: idea labels and
// statements, the development prose, themes, gaps, notes, summaries, the names of collections.
//
// What does not is the bibliography and the quotations. A work is catalogued under the title
// of the edition you actually hold, and a passage is the source text — a Spanish vault built
// on English sources quotes them in English, because that is what the page says. Translating
// either would mean inventing an edition nobody owns and attributing a translation to nobody.
//
// Everything is inserted through the desktop's own migrated schema (see make-demo-snapshot.mjs),
// so a column renamed by a later migration fails here loudly instead of shipping a snapshot the
// app reads as empty.

import { createHash } from 'node:crypto';

/** The interface languages the app ships, and therefore the snapshots this builds. */
export const LOCALES = ['en', 'es'];

/** Pick one language out of a `{ en, es }` value; a plain string is the same in both. */
const t = (value, locale) => (typeof value === 'string' ? value : value[locale] ?? value.en);

/** What the space calls itself. `academic` because that is what a bibliography is. */
export function demoVault(locale) {
  return {
    id: 'nodus-demo-vault',
    name: t({
      en: 'Liberty, Education and the Individual',
      es: 'Libertad, educación e individuo',
    }, locale),
    type: 'academic',
  };
}

// One fixed instant for everything.
//
// `buildServerSnapshot` hashes the tables to produce the revision, so a `new Date()` anywhere
// in here would give the same corpus a different revision on every run — and the committed
// .gz would show up as changed in every diff that touched this file.
const AT = '2026-01-15T09:00:00.000Z';

const hash = (value) => createHash('sha256').update(String(value)).digest('hex');

// ── The library ──────────────────────────────────────────────────────────────
//
// `authors_json` is CSL-shaped, which is what Zotero gives the desktop and what
// `RowPresenter.authorList` reads. `read_tag` marks the ones a reader has been through.
// Titles are the edition's own; only the editorial note beside them is translated.

const WORKS = [
  {
    id: 'demo-w-mill-liberty',
    title: 'On Liberty',
    authors: [{ family: 'Mill', given: 'John Stuart' }],
    year: 1859,
    type: 'book',
    read: true,
    note: {
      en: 'Longman, Roberts & Green edition. Public domain.',
      es: 'Edición de Longman, Roberts & Green. Dominio público.',
    },
  },
  {
    id: 'demo-w-wollstonecraft-vindication',
    title: 'A Vindication of the Rights of Woman',
    authors: [{ family: 'Wollstonecraft', given: 'Mary' }],
    year: 1792,
    type: 'book',
    read: true,
    note: {
      en: 'First edition, London. Public domain.',
      es: 'Primera edición, Londres. Dominio público.',
    },
  },
  {
    id: 'demo-w-rousseau-emile',
    title: 'Émile, or On Education',
    authors: [{ family: 'Rousseau', given: 'Jean-Jacques' }],
    year: 1762,
    type: 'book',
    read: true,
    note: {
      en: 'Foxley translation. Public domain.',
      es: 'Traducción inglesa de Foxley. Dominio público.',
    },
  },
  {
    id: 'demo-w-tocqueville-democracy',
    title: 'Democracy in America, Volume II',
    authors: [{ family: 'Tocqueville', given: 'Alexis de' }],
    year: 1840,
    type: 'book',
    read: true,
    note: {
      en: 'Reeve translation. Public domain.',
      es: 'Traducción inglesa de Reeve. Dominio público.',
    },
  },
  {
    id: 'demo-w-dubois-souls',
    title: 'The Souls of Black Folk',
    authors: [{ family: 'Du Bois', given: 'W. E. B.' }],
    year: 1903,
    type: 'book',
    read: true,
    note: {
      en: 'A. C. McClurg & Co. Public domain.',
      es: 'A. C. McClurg & Co. Dominio público.',
    },
  },
  {
    id: 'demo-w-smith-wealth',
    title: 'An Inquiry into the Nature and Causes of the Wealth of Nations',
    authors: [{ family: 'Smith', given: 'Adam' }],
    year: 1776,
    type: 'book',
    read: false,
    note: {
      en: 'Cannan edition. Public domain.',
      es: 'Edición de Cannan. Dominio público.',
    },
  },
  {
    id: 'demo-w-kant-enlightenment',
    title: 'An Answer to the Question: What Is Enlightenment?',
    authors: [{ family: 'Kant', given: 'Immanuel' }],
    year: 1784,
    type: 'journalArticle',
    read: true,
    note: {
      en: 'Berlinische Monatsschrift. English translation, public domain.',
      es: 'Berlinische Monatsschrift. Traducción inglesa, dominio público.',
    },
  },
  {
    id: 'demo-w-marx-manifesto',
    title: 'Manifesto of the Communist Party',
    authors: [{ family: 'Marx', given: 'Karl' }, { family: 'Engels', given: 'Friedrich' }],
    year: 1848,
    type: 'book',
    read: true,
    note: {
      en: 'Moore translation of 1888. Public domain.',
      es: 'Traducción inglesa de Moore, 1888. Dominio público.',
    },
  },
  {
    id: 'demo-w-darwin-origin',
    title: 'On the Origin of Species by Means of Natural Selection',
    authors: [{ family: 'Darwin', given: 'Charles' }],
    year: 1859,
    type: 'book',
    read: false,
    note: {
      en: 'First edition, John Murray. Public domain.',
      es: 'Primera edición, John Murray. Dominio público.',
    },
  },
  {
    id: 'demo-w-thoreau-disobedience',
    title: 'Resistance to Civil Government',
    authors: [{ family: 'Thoreau', given: 'Henry David' }],
    year: 1849,
    type: 'bookSection',
    read: false,
    note: {
      en: 'In Aesthetic Papers. Public domain.',
      es: 'En Aesthetic Papers. Dominio público.',
    },
  },
];

const AUTHORS = [
  { id: 'demo-a-mill', name: 'John Stuart Mill', works: ['demo-w-mill-liberty'] },
  { id: 'demo-a-wollstonecraft', name: 'Mary Wollstonecraft', works: ['demo-w-wollstonecraft-vindication'] },
  { id: 'demo-a-rousseau', name: 'Jean-Jacques Rousseau', works: ['demo-w-rousseau-emile'] },
  { id: 'demo-a-tocqueville', name: 'Alexis de Tocqueville', works: ['demo-w-tocqueville-democracy'] },
  { id: 'demo-a-dubois', name: 'W. E. B. Du Bois', works: ['demo-w-dubois-souls'] },
  { id: 'demo-a-smith', name: 'Adam Smith', works: ['demo-w-smith-wealth'] },
  { id: 'demo-a-kant', name: 'Immanuel Kant', works: ['demo-w-kant-enlightenment'] },
  { id: 'demo-a-marx', name: 'Karl Marx', works: ['demo-w-marx-manifesto'] },
  { id: 'demo-a-engels', name: 'Friedrich Engels', works: ['demo-w-marx-manifesto'] },
  { id: 'demo-a-darwin', name: 'Charles Darwin', works: ['demo-w-darwin-origin'] },
  { id: 'demo-a-thoreau', name: 'Henry David Thoreau', works: ['demo-w-thoreau-disobedience'] },
];

/** Who read whom, as the dossier screen draws it. Weight is how load-bearing the link is. */
const AUTHOR_RELATIONS = [
  { from: 'demo-a-wollstonecraft', to: 'demo-a-rousseau', type: 'responds_to', weight: 0.95 },
  { from: 'demo-a-mill', to: 'demo-a-tocqueville', type: 'cites', weight: 0.8 },
  { from: 'demo-a-marx', to: 'demo-a-smith', type: 'critiques', weight: 0.85 },
  { from: 'demo-a-dubois', to: 'demo-a-mill', type: 'extends', weight: 0.5 },
  { from: 'demo-a-thoreau', to: 'demo-a-mill', type: 'converges_with', weight: 0.45 },
];

const THEMES = [
  {
    id: 'demo-t-liberty',
    label: { en: 'Liberty and its limits', es: 'La libertad y sus límites' },
    pinned: 1,
  },
  {
    id: 'demo-t-education',
    label: { en: 'Education and the formation of character', es: 'Educación y formación del carácter' },
    pinned: 1,
  },
  {
    id: 'demo-t-mass',
    label: { en: 'Individualism and mass society', es: 'Individualismo y sociedad de masas' },
    pinned: 0,
  },
  {
    id: 'demo-t-labour',
    label: { en: 'Labour, wealth and the person', es: 'Trabajo, riqueza y persona' },
    pinned: 0,
  },
  {
    id: 'demo-t-recognition',
    label: { en: 'Recognition and exclusion', es: 'Reconocimiento y exclusión' },
    pinned: 0,
  },
  {
    id: 'demo-t-change',
    label: { en: 'Nature, history and change', es: 'Naturaleza, historia y cambio' },
    pinned: 0,
  },
];

// ── The analysis ─────────────────────────────────────────────────────────────
//
// One idea per position actually taken in one of the works above, with the quotation it rests
// on. `role` is the part the idea plays in the work it occurs in; `confidence` is how firmly
// the work states it, and is what the detail screen shows as a bar.

const IDEAS = [
  {
    id: 'demo-i-harm-principle',
    type: 'claim',
    label: { en: 'The harm principle', es: 'El principio del daño' },
    statement: {
      en: 'Society may coerce an individual only to prevent harm to others; a person’s own good is never sufficient warrant.',
      es: 'La sociedad solo puede coaccionar a alguien para impedir un daño a terceros; su propio bien nunca basta como justificación.',
    },
    theme: 'demo-t-liberty',
    work: 'demo-w-mill-liberty',
    role: 'claim',
    confidence: 0.95,
    development: {
      en: 'Mill states it as the "one very simple principle" the essay exists to defend, and immediately concedes it applies only to beings in the maturity of their faculties — a qualification the rest of the argument leans on more heavily than it admits.',
      es: 'Mill lo enuncia como el «principio muy sencillo» que el ensayo existe para defender, y acto seguido concede que solo vale para quien está en la madurez de sus facultades: una salvedad en la que el resto del argumento se apoya más de lo que reconoce.',
    },
    evidence: {
      quote: 'The only purpose for which power can be rightfully exercised over any member of a civilised community, against his will, is to prevent harm to others.',
      location: 'ch. I',
    },
  },
  {
    id: 'demo-i-own-good-own-way',
    type: 'claim',
    label: {
      en: 'Freedom is pursuing one’s own good in one’s own way',
      es: 'La libertad es buscar el propio bien a la propia manera',
    },
    statement: {
      en: 'The only liberty worth the name is the liberty to seek one’s own good by one’s own route, so long as others are not deprived of theirs.',
      es: 'La única libertad que merece el nombre es la de buscar el propio bien por el propio camino, mientras no se prive a los demás del suyo.',
    },
    theme: 'demo-t-liberty',
    work: 'demo-w-mill-liberty',
    role: 'definition',
    confidence: 0.9,
    development: {
      en: 'This is the positive statement the harm principle is the negative of, and it is where Mill’s liberalism becomes a claim about what a life is for rather than about what a state may do.',
      es: 'Es el enunciado positivo del que el principio del daño es el negativo, y es donde el liberalismo de Mill deja de hablar de lo que el Estado puede hacer y pasa a hablar de para qué sirve una vida.',
    },
    evidence: {
      quote: 'The only freedom which deserves the name is that of pursuing our own good in our own way, so long as we do not attempt to deprive others of theirs, or impede their efforts to obtain it.',
      location: 'ch. I',
    },
  },
  {
    id: 'demo-i-tyranny-majority',
    type: 'construct',
    label: { en: 'The tyranny of the majority', es: 'La tiranía de la mayoría' },
    statement: {
      en: 'Opinion coerces more thoroughly than law, because it penetrates the details of life where no magistrate reaches.',
      es: 'La opinión coacciona más a fondo que la ley, porque penetra en los detalles de la vida donde ningún magistrado llega.',
    },
    theme: 'demo-t-mass',
    work: 'demo-w-mill-liberty',
    role: 'context',
    confidence: 0.85,
    development: {
      en: 'Mill takes the phrase from Tocqueville and moves it: for Tocqueville the danger is to political minorities, for Mill it is to the eccentric individual, and the remedy shifts accordingly from institutions to habits.',
      es: 'Mill toma la expresión de Tocqueville y la desplaza: para Tocqueville el peligro amenaza a las minorías políticas; para Mill, al individuo excéntrico. El remedio se desplaza con ella, de las instituciones a las costumbres.',
    },
    evidence: {
      quote: 'Protection, therefore, against the tyranny of the magistrate is not enough: there needs protection also against the tyranny of the prevailing opinion and feeling.',
      location: 'ch. I',
    },
  },
  {
    id: 'demo-i-soft-despotism',
    type: 'construct',
    label: { en: 'The mild despotism of equality', es: 'El despotismo apacible de la igualdad' },
    statement: {
      en: 'A democratic society may end in an administrative power that is regular and provident rather than tyrannical, and that leaves its citizens nothing to do but consent.',
      es: 'Una sociedad democrática puede acabar en un poder administrativo regular y previsor, más que tiránico, que no deja a sus ciudadanos otra cosa que consentir.',
    },
    theme: 'demo-t-mass',
    work: 'demo-w-tocqueville-democracy',
    role: 'claim',
    confidence: 0.85,
    development: {
      en: 'Tocqueville’s despotism is not violent; it is a network of small rules that no one resents individually and that together make initiative unnecessary. The argument depends on the reader accepting that comfort can be a form of subjection.',
      es: 'El despotismo de Tocqueville no es violento: es una red de reglas menudas que nadie resiente por separado y que juntas vuelven innecesaria la iniciativa. El argumento exige aceptar que la comodidad puede ser una forma de sujeción.',
    },
    evidence: {
      quote: 'It covers the surface of society with a network of small complicated rules, minute and uniform, through which the most original minds and the most energetic characters cannot penetrate.',
      location: 'vol. II, bk. IV, ch. VI',
    },
  },
  {
    id: 'demo-i-individualism-novel',
    type: 'finding',
    label: {
      en: 'Individualism as a new word for a new thing',
      es: 'El individualismo, palabra nueva para una cosa nueva',
    },
    statement: {
      en: 'Individualism is not selfishness but a considered withdrawal from public life, and it is produced by equality rather than by vice.',
      es: 'El individualismo no es egoísmo, sino una retirada deliberada de la vida pública, y lo produce la igualdad antes que el vicio.',
    },
    theme: 'demo-t-mass',
    work: 'demo-w-tocqueville-democracy',
    role: 'definition',
    confidence: 0.8,
    development: {
      en: 'Distinguishing individualism from egoism is what lets Tocqueville treat it as a structural effect rather than a moral failing, and therefore as something institutions might counteract.',
      es: 'Distinguir individualismo de egoísmo es lo que permite a Tocqueville tratarlo como un efecto estructural y no como una falta moral, y por tanto como algo que las instituciones podrían contrarrestar.',
    },
    evidence: {
      quote: 'Individualism is a novel expression, to which a novel idea has given birth.',
      location: 'vol. II, bk. II, ch. II',
    },
  },
  {
    id: 'demo-i-sapere-aude',
    type: 'claim',
    label: {
      en: 'Enlightenment is self-incurred immaturity overcome',
      es: 'La ilustración es salir de una minoría de edad culpable',
    },
    statement: {
      en: 'The obstacle to thinking for oneself is not a lack of understanding but a lack of resolve, so the remedy is courage rather than instruction.',
      es: 'Lo que impide pensar por uno mismo no es falta de entendimiento sino falta de decisión; el remedio es el valor, no la instrucción.',
    },
    theme: 'demo-t-education',
    work: 'demo-w-kant-enlightenment',
    role: 'claim',
    confidence: 0.95,
    development: {
      en: 'Locating the fault in the will rather than in the intellect is what makes the essay a political argument: if immaturity is chosen, then guardianship is complicity, and freedom is the only cure.',
      es: 'Situar la culpa en la voluntad y no en el intelecto es lo que convierte el ensayo en un argumento político: si la minoría de edad se elige, la tutela es complicidad y la libertad es la única cura.',
    },
    evidence: {
      quote: 'Enlightenment is man’s emergence from his self-incurred immaturity. Sapere aude! Have courage to use your own understanding!',
      location: 'opening',
    },
  },
  {
    id: 'demo-i-strengthen-female-mind',
    type: 'claim',
    label: { en: 'Reason is not sexed', es: 'La razón no tiene sexo' },
    statement: {
      en: 'Women appear weak in understanding because they are educated for ornament; enlarge the mind and blind obedience ends with it.',
      es: 'Las mujeres parecen débiles de entendimiento porque se las educa para el adorno; ensánchese la mente y con ella termina la obediencia ciega.',
    },
    theme: 'demo-t-education',
    work: 'demo-w-wollstonecraft-vindication',
    role: 'claim',
    confidence: 0.95,
    development: {
      en: 'Wollstonecraft accepts the observation her opponents make — that women reason badly — and refuses their explanation of it. The whole argument turns on treating an effect of education as if it were a fact of nature.',
      es: 'Wollstonecraft acepta la observación de sus adversarios —que las mujeres razonan mal— y rechaza su explicación. Todo el argumento gira sobre tomar un efecto de la educación por un hecho de la naturaleza.',
    },
    evidence: {
      quote: 'Strengthen the female mind by enlarging it, and there will be an end to blind obedience.',
      location: 'ch. IV',
    },
  },
  {
    id: 'demo-i-power-over-themselves',
    type: 'claim',
    label: { en: 'Power over themselves, not over men', es: 'Poder sobre sí mismas, no sobre los hombres' },
    statement: {
      en: 'The claim being made for women is self-command, not dominion, which is why it is compatible with every duty its opponents fear for.',
      es: 'Lo que se reclama para las mujeres es dominio de sí, no dominio sobre otros; por eso es compatible con todos los deberes que sus adversarios temen perder.',
    },
    theme: 'demo-t-recognition',
    work: 'demo-w-wollstonecraft-vindication',
    role: 'claim',
    confidence: 0.9,
    development: {
      en: 'A pre-emptive answer to the charge of usurpation, and the sentence that most often stands in for the book. It concedes nothing while sounding conciliatory.',
      es: 'Una respuesta anticipada a la acusación de usurpación, y la frase que más veces se cita en lugar del libro. No concede nada y suena conciliadora.',
    },
    evidence: {
      quote: 'I do not wish them to have power over men; but over themselves.',
      location: 'ch. IV',
    },
  },
  {
    id: 'demo-i-education-for-pleasing',
    type: 'claim',
    label: { en: 'Woman is formed to please', es: 'La mujer está formada para agradar' },
    statement: {
      en: 'The education of a woman should be relative to a man: to please him, to be useful to him, and to make his life sweet.',
      es: 'La educación de la mujer debe ser relativa al hombre: agradarle, serle útil y endulzarle la vida.',
    },
    theme: 'demo-t-education',
    work: 'demo-w-rousseau-emile',
    role: 'claim',
    confidence: 0.9,
    development: {
      en: 'Book V is where Émile’s natural education stops being universal. The same author who insists a boy be formed by nothing but nature prescribes for Sophie an education defined entirely by another person’s needs.',
      es: 'El libro V es donde la educación natural de Emilio deja de ser universal. El mismo autor que exige que a un niño no lo forme más que la naturaleza le prescribe a Sofía una educación definida por entero por las necesidades de otro.',
    },
    evidence: {
      quote: 'The whole education of women ought to be relative to men. To please them, to be useful to them, to make themselves loved and honoured by them.',
      location: 'bk. V',
    },
  },
  {
    id: 'demo-i-nature-degenerates',
    type: 'framework',
    label: {
      en: 'Everything degenerates in the hands of man',
      es: 'Todo degenera en las manos del hombre',
    },
    statement: {
      en: 'What comes from nature is good and is spoiled by society, so education must protect rather than form.',
      es: 'Lo que viene de la naturaleza es bueno y la sociedad lo echa a perder, de modo que la educación debe proteger antes que formar.',
    },
    theme: 'demo-t-education',
    work: 'demo-w-rousseau-emile',
    role: 'context',
    confidence: 0.9,
    development: {
      en: 'The premise the whole of Émile rests on, and the one that makes its programme negative: the tutor’s art is to keep the world away long enough for nature to work.',
      es: 'La premisa sobre la que descansa todo el Emilio, y la que vuelve negativo su programa: el arte del preceptor consiste en mantener el mundo a raya el tiempo suficiente para que la naturaleza obre.',
    },
    evidence: {
      quote: 'Everything is good as it leaves the hands of the Author of things; everything degenerates in the hands of man.',
      location: 'bk. I, opening',
    },
  },
  {
    id: 'demo-i-double-consciousness',
    type: 'construct',
    label: { en: 'Double consciousness', es: 'La doble conciencia' },
    statement: {
      en: 'Exclusion produces a self seen through the eyes of those who despise it, and therefore two irreconcilable selves in one body.',
      es: 'La exclusión produce un yo visto por los ojos de quienes lo desprecian, y por tanto dos yoes irreconciliables en un mismo cuerpo.',
    },
    theme: 'demo-t-recognition',
    work: 'demo-w-dubois-souls',
    role: 'claim',
    confidence: 0.95,
    development: {
      en: 'Du Bois turns a psychological description into a claim about the structure of a society: the doubling is not a defect of the person but a measurement of the world they are asked to live in.',
      es: 'Du Bois convierte una descripción psicológica en una tesis sobre la estructura de una sociedad: el desdoblamiento no es un defecto de la persona, sino una medida del mundo en que se le pide vivir.',
    },
    evidence: {
      quote: 'One ever feels his two-ness,—an American, a Negro; two souls, two thoughts, two unreconciled strivings; two warring ideals in one dark body.',
      location: 'ch. I',
    },
  },
  {
    id: 'demo-i-colour-line',
    type: 'claim',
    label: { en: 'The problem of the colour line', es: 'El problema de la línea de color' },
    statement: {
      en: 'The defining political problem of the century is the line drawn between races, not the extension of liberty as such.',
      es: 'El problema político que define el siglo es la línea trazada entre razas, no la extensión de la libertad como tal.',
    },
    theme: 'demo-t-recognition',
    work: 'demo-w-dubois-souls',
    role: 'claim',
    confidence: 0.95,
    development: {
      en: 'Stated in the Forethought as the thesis of the whole book, and framed globally rather than as an American question.',
      es: 'Enunciado en el prefacio como tesis de todo el libro, y planteado en términos mundiales antes que como una cuestión estadounidense.',
    },
    evidence: {
      quote: 'The problem of the Twentieth Century is the problem of the color-line.',
      location: 'Forethought',
    },
  },
  {
    id: 'demo-i-invisible-hand',
    type: 'claim',
    label: {
      en: 'Exchange rests on interest, not benevolence',
      es: 'El intercambio descansa en el interés, no en la benevolencia',
    },
    statement: {
      en: 'The provision of ordinary needs is secured by each party’s regard to their own advantage, not by anyone’s goodwill.',
      es: 'Las necesidades corrientes quedan cubiertas porque cada parte atiende a su propia ventaja, no por la buena voluntad de nadie.',
    },
    theme: 'demo-t-labour',
    work: 'demo-w-smith-wealth',
    role: 'claim',
    confidence: 0.9,
    development: {
      en: 'The sentence is usually read as a defence of self-interest; in place it is an observation about how a division of labour coordinates strangers who have no reason to care about one another.',
      es: 'La frase suele leerse como una defensa del interés propio; en su lugar es una observación sobre cómo la división del trabajo coordina a desconocidos que no tienen motivo alguno para importarse.',
    },
    evidence: {
      quote: 'It is not from the benevolence of the butcher, the brewer, or the baker that we expect our dinner, but from their regard to their own interest.',
      location: 'bk. I, ch. II',
    },
  },
  {
    id: 'demo-i-division-stupefies',
    type: 'finding',
    label: {
      en: 'The division of labour stupefies the labourer',
      es: 'La división del trabajo embrutece al trabajador',
    },
    statement: {
      en: 'A life spent in a few simple operations destroys the understanding it does not need, and public instruction is required to repair it.',
      es: 'Una vida pasada en unas pocas operaciones sencillas destruye el entendimiento que no necesita, y hace falta instrucción pública para repararlo.',
    },
    theme: 'demo-t-labour',
    work: 'demo-w-smith-wealth',
    role: 'contrast',
    confidence: 0.85,
    development: {
      en: 'Book V says plainly what Book I is usually quoted against: the same arrangement that makes a nation rich makes the person who works in it less than they were. Smith’s remedy is compulsory public education, which is not the conclusion he is normally credited with.',
      es: 'El libro V dice sin rodeos aquello contra lo que suele citarse el libro I: el mismo arreglo que enriquece a una nación empequeñece a quien trabaja en él. El remedio de Smith es la enseñanza pública obligatoria, que no es la conclusión que se le suele atribuir.',
    },
    evidence: {
      quote: 'The man whose whole life is spent in performing a few simple operations… generally becomes as stupid and ignorant as it is possible for a human creature to become.',
      location: 'bk. V, ch. I, pt. III',
    },
  },
  {
    id: 'demo-i-class-struggle',
    type: 'framework',
    label: {
      en: 'History as the history of class struggle',
      es: 'La historia como historia de la lucha de clases',
    },
    statement: {
      en: 'The motor of historical change is the conflict of classes defined by their place in production, not the progress of ideas.',
      es: 'El motor del cambio histórico es el conflicto de clases definidas por su lugar en la producción, no el progreso de las ideas.',
    },
    theme: 'demo-t-change',
    work: 'demo-w-marx-manifesto',
    role: 'claim',
    confidence: 0.95,
    development: {
      en: 'Announced in the first sentence of Part I, which makes every later argument in the pamphlet a specification of it rather than a separate claim.',
      es: 'Se anuncia en la primera frase de la parte I, lo que convierte cada argumento posterior del panfleto en una especificación suya y no en una tesis aparte.',
    },
    evidence: {
      quote: 'The history of all hitherto existing society is the history of class struggles.',
      location: 'pt. I',
    },
  },
  {
    id: 'demo-i-all-solid-melts',
    type: 'finding',
    label: {
      en: 'Bourgeois society dissolves its own conditions',
      es: 'La sociedad burguesa disuelve sus propias condiciones',
    },
    statement: {
      en: 'Constant revolution in production makes every settled relation obsolete before it can ossify, which is the bourgeoisie’s achievement and its danger.',
      es: 'La revolución constante de la producción vuelve obsoleta toda relación asentada antes de que pueda osificarse: ese es el logro de la burguesía y también su peligro.',
    },
    theme: 'demo-t-change',
    work: 'demo-w-marx-manifesto',
    role: 'support',
    confidence: 0.9,
    development: {
      en: 'The passage is admiring, which is easy to miss: the dissolving of fixed relations is described as an accomplishment before it is turned into a prediction.',
      es: 'El pasaje es admirativo, cosa fácil de pasar por alto: la disolución de las relaciones fijas se describe como una hazaña antes de convertirse en un pronóstico.',
    },
    evidence: {
      quote: 'All that is solid melts into air, all that is holy is profaned, and man is at last compelled to face with sober senses his real conditions of life.',
      location: 'pt. I',
    },
  },
  {
    id: 'demo-i-descent-with-modification',
    type: 'framework',
    label: { en: 'Descent with modification', es: 'Descendencia con modificación' },
    statement: {
      en: 'Forms are not fixed kinds but the outcome of a history of small inherited variation under selection.',
      es: 'Las formas no son especies fijas, sino el resultado de una historia de pequeñas variaciones heredadas bajo selección.',
    },
    theme: 'demo-t-change',
    work: 'demo-w-darwin-origin',
    role: 'claim',
    confidence: 0.95,
    development: {
      en: 'The closing paragraph states the position as a view of life rather than as a mechanism, which is what allowed it to be read straight across into arguments about societies it says nothing about.',
      es: 'El párrafo final enuncia la posición como una visión de la vida y no como un mecanismo, y eso es lo que permitió trasladarla sin más a discusiones sobre sociedades de las que no dice nada.',
    },
    evidence: {
      quote: 'There is grandeur in this view of life… from so simple a beginning endless forms most beautiful and most wonderful have been, and are being, evolved.',
      location: 'ch. XIV',
    },
  },
  {
    id: 'demo-i-conscience-over-law',
    type: 'claim',
    label: { en: 'Conscience before legislature', es: 'La conciencia antes que el legislador' },
    statement: {
      en: 'A citizen owes obedience to their own sense of right before any majority’s, and withdrawal of support is the proper form of refusal.',
      es: 'El ciudadano debe obediencia a su propio sentido de lo justo antes que al de ninguna mayoría, y retirar el apoyo es la forma propia de negarse.',
    },
    theme: 'demo-t-liberty',
    work: 'demo-w-thoreau-disobedience',
    role: 'claim',
    confidence: 0.85,
    development: {
      en: 'Thoreau reaches an anti-majoritarian conclusion from a premise Mill shares, and does it without Mill’s concern for what the refusal costs anybody else.',
      es: 'Thoreau llega a una conclusión antimayoritaria desde una premisa que Mill comparte, y lo hace sin la preocupación de Mill por lo que esa negativa le cuesta a los demás.',
    },
    evidence: {
      quote: 'Must the citizen ever for a moment, or in the least degree, resign his conscience to the legislator? Why has every man a conscience, then?',
      location: 'opening',
    },
  },
];

/** An idea can belong to more than one theme; these are the second homes. */
const EXTRA_THEME_LINKS = [
  { idea: 'demo-i-division-stupefies', theme: 'demo-t-education' },
  { idea: 'demo-i-double-consciousness', theme: 'demo-t-mass' },
  { idea: 'demo-i-tyranny-majority', theme: 'demo-t-liberty' },
  { idea: 'demo-i-conscience-over-law', theme: 'demo-t-mass' },
  { idea: 'demo-i-class-struggle', theme: 'demo-t-labour' },
];

// The graph. `contradicts` and `refutes` are the two relations the Debates screen is built
// from, so the corpus needs real ones — a demo whose Analyse section is empty teaches the
// reader that the section is empty.
const EDGES = [
  {
    id: 'demo-e-1',
    from: 'demo-i-strengthen-female-mind',
    to: 'demo-i-education-for-pleasing',
    type: 'refutes',
    basis: 'explicit',
    confidence: 0.95,
    work: 'demo-w-wollstonecraft-vindication',
  },
  {
    id: 'demo-e-2',
    from: 'demo-i-division-stupefies',
    to: 'demo-i-invisible-hand',
    type: 'contradicts',
    basis: 'inferred',
    confidence: 0.7,
    work: 'demo-w-smith-wealth',
  },
  {
    id: 'demo-e-3',
    from: 'demo-i-class-struggle',
    to: 'demo-i-harm-principle',
    type: 'contradicts',
    basis: 'inferred',
    confidence: 0.75,
    work: 'demo-w-marx-manifesto',
  },
  {
    id: 'demo-e-4',
    from: 'demo-i-colour-line',
    to: 'demo-i-own-good-own-way',
    type: 'contradicts',
    basis: 'inferred',
    confidence: 0.65,
    work: 'demo-w-dubois-souls',
  },
  {
    id: 'demo-e-5',
    from: 'demo-i-soft-despotism',
    to: 'demo-i-tyranny-majority',
    type: 'supports',
    basis: 'explicit',
    confidence: 0.85,
    work: 'demo-w-mill-liberty',
  },
  {
    id: 'demo-e-6',
    from: 'demo-i-tyranny-majority',
    to: 'demo-i-harm-principle',
    type: 'precondition_of',
    basis: 'inferred',
    confidence: 0.7,
    work: 'demo-w-mill-liberty',
  },
  {
    id: 'demo-e-7',
    from: 'demo-i-power-over-themselves',
    to: 'demo-i-strengthen-female-mind',
    type: 'extends',
    basis: 'explicit',
    confidence: 0.8,
    work: 'demo-w-wollstonecraft-vindication',
  },
  {
    id: 'demo-e-8',
    from: 'demo-i-conscience-over-law',
    to: 'demo-i-own-good-own-way',
    type: 'refines',
    basis: 'inferred',
    confidence: 0.6,
    work: 'demo-w-thoreau-disobedience',
  },
  {
    id: 'demo-e-9',
    from: 'demo-i-sapere-aude',
    to: 'demo-i-strengthen-female-mind',
    type: 'supports',
    basis: 'inferred',
    confidence: 0.75,
    work: 'demo-w-kant-enlightenment',
  },
  {
    id: 'demo-e-10',
    from: 'demo-i-all-solid-melts',
    to: 'demo-i-class-struggle',
    type: 'supports',
    basis: 'explicit',
    confidence: 0.9,
    work: 'demo-w-marx-manifesto',
  },
  {
    id: 'demo-e-11',
    from: 'demo-i-descent-with-modification',
    to: 'demo-i-nature-degenerates',
    type: 'contradicts',
    basis: 'inferred',
    confidence: 0.55,
    work: 'demo-w-darwin-origin',
  },
  {
    id: 'demo-e-12',
    from: 'demo-i-double-consciousness',
    to: 'demo-i-colour-line',
    type: 'supports',
    basis: 'explicit',
    confidence: 0.9,
    work: 'demo-w-dubois-souls',
  },
];

const GAPS = [
  {
    id: 'demo-g-1',
    work: 'demo-w-mill-liberty',
    idea: 'demo-i-harm-principle',
    kind: 'open_question',
    statement: {
      en: 'Mill exempts "backward states of society" from the harm principle and never says what would end that exemption.',
      es: 'Mill exceptúa del principio del daño a los «estados atrasados de la sociedad» y nunca dice qué pondría fin a esa excepción.',
    },
    confidence: 0.85,
  },
  {
    id: 'demo-g-2',
    work: 'demo-w-smith-wealth',
    idea: 'demo-i-division-stupefies',
    kind: 'unresolved_contradiction',
    statement: {
      en: 'Nothing in the corpus reconciles Book I’s praise of the division of labour with Book V’s account of what it does to the labourer.',
      es: 'Nada en el corpus concilia el elogio de la división del trabajo del libro I con lo que el libro V dice que esa división le hace al trabajador.',
    },
    confidence: 0.75,
  },
  {
    id: 'demo-g-3',
    work: 'demo-w-dubois-souls',
    idea: 'demo-i-colour-line',
    kind: 'future_work',
    statement: {
      en: 'No work here tests whether the harm principle can name exclusion as harm, which is the question Du Bois puts to liberalism.',
      es: 'Ninguna obra de aquí comprueba si el principio del daño puede llamar daño a la exclusión, que es la pregunta que Du Bois le hace al liberalismo.',
    },
    confidence: 0.7,
  },
];

// Passages: the text a citation resolves against. Every one is verbatim from the public-domain
// edition named in the work’s note, and therefore in that edition’s own language.
const PASSAGES = [
  {
    work: 'demo-w-mill-liberty',
    page: 'ch. I',
    text: 'That the only purpose for which power can be rightfully exercised over any member of a civilised community, against his will, is to prevent harm to others. His own good, either physical or moral, is not a sufficient warrant.',
  },
  {
    work: 'demo-w-mill-liberty',
    page: 'ch. I',
    text: 'The only freedom which deserves the name is that of pursuing our own good in our own way, so long as we do not attempt to deprive others of theirs, or impede their efforts to obtain it.',
  },
  {
    work: 'demo-w-mill-liberty',
    page: 'ch. II',
    text: 'If all mankind minus one were of one opinion, and only one person were of the contrary opinion, mankind would be no more justified in silencing that one person than he, if he had the power, would be justified in silencing mankind.',
  },
  {
    work: 'demo-w-mill-liberty',
    page: 'ch. III',
    text: 'He who lets the world, or his own portion of it, choose his plan of life for him, has no need of any other faculty than the ape-like one of imitation.',
  },
  {
    work: 'demo-w-wollstonecraft-vindication',
    page: 'ch. IV',
    text: 'I do not wish them to have power over men; but over themselves.',
  },
  {
    work: 'demo-w-wollstonecraft-vindication',
    page: 'ch. IV',
    text: 'Strengthen the female mind by enlarging it, and there will be an end to blind obedience.',
  },
  {
    work: 'demo-w-wollstonecraft-vindication',
    page: 'Introduction',
    text: 'I wish to persuade women to endeavour to acquire strength, both of mind and body, and to convince them that the soft phrases, susceptibility of heart, delicacy of sentiment, and refinement of taste, are almost synonymous with epithets of weakness.',
  },
  {
    work: 'demo-w-rousseau-emile',
    page: 'bk. I',
    text: 'Everything is good as it leaves the hands of the Author of things; everything degenerates in the hands of man.',
  },
  {
    work: 'demo-w-rousseau-emile',
    page: 'bk. V',
    text: 'The whole education of women ought to be relative to men. To please them, to be useful to them, to make themselves loved and honoured by them, to educate them when young, to care for them when grown.',
  },
  {
    work: 'demo-w-tocqueville-democracy',
    page: 'bk. II, ch. II',
    text: 'Individualism is a novel expression, to which a novel idea has given birth. Our fathers were only acquainted with egotism.',
  },
  {
    work: 'demo-w-tocqueville-democracy',
    page: 'bk. IV, ch. VI',
    text: 'It covers the surface of society with a network of small complicated rules, minute and uniform, through which the most original minds and the most energetic characters cannot penetrate, to rise above the crowd.',
  },
  {
    work: 'demo-w-dubois-souls',
    page: 'Forethought',
    text: 'Herein lie buried many things which if read with patience may show the strange meaning of being black here at the dawning of the Twentieth Century. This meaning is not without interest to you, Gentle Reader; for the problem of the Twentieth Century is the problem of the color-line.',
  },
  {
    work: 'demo-w-dubois-souls',
    page: 'ch. I',
    text: 'One ever feels his two-ness,—an American, a Negro; two souls, two thoughts, two unreconciled strivings; two warring ideals in one dark body, whose dogged strength alone keeps it from being torn asunder.',
  },
  {
    work: 'demo-w-smith-wealth',
    page: 'bk. I, ch. II',
    text: 'It is not from the benevolence of the butcher, the brewer, or the baker that we expect our dinner, but from their regard to their own interest. We address ourselves, not to their humanity but to their self-love.',
  },
  {
    work: 'demo-w-smith-wealth',
    page: 'bk. V, ch. I',
    text: 'The man whose whole life is spent in performing a few simple operations, of which the effects too are, perhaps, always the same, or very nearly the same, has no occasion to exert his understanding.',
  },
  {
    work: 'demo-w-kant-enlightenment',
    page: 'opening',
    text: 'Enlightenment is man’s emergence from his self-incurred immaturity. Immaturity is the inability to use one’s own understanding without the guidance of another. Sapere aude! Have courage to use your own understanding!',
  },
  {
    work: 'demo-w-marx-manifesto',
    page: 'pt. I',
    text: 'The history of all hitherto existing society is the history of class struggles.',
  },
  {
    work: 'demo-w-marx-manifesto',
    page: 'pt. I',
    text: 'All that is solid melts into air, all that is holy is profaned, and man is at last compelled to face with sober senses his real conditions of life, and his relations with his kind.',
  },
  {
    work: 'demo-w-darwin-origin',
    page: 'ch. XIV',
    text: 'There is grandeur in this view of life, with its several powers, having been originally breathed into a few forms or into one; and that, whilst this planet has gone cycling on according to the fixed law of gravity, from so simple a beginning endless forms most beautiful and most wonderful have been, and are being, evolved.',
  },
  {
    work: 'demo-w-thoreau-disobedience',
    page: 'opening',
    text: 'Must the citizen ever for a moment, or in the least degree, resign his conscience to the legislator? Why has every man a conscience, then?',
  },
];

const SUMMARIES = [
  {
    work: 'demo-w-mill-liberty',
    text: {
      en: 'An argument that the only ground for coercing an adult is harm to others, developed through three applications: freedom of opinion, freedom of life-plan, and the limits of what a society may enforce through opinion rather than law. The essay’s difficulty is its own exception for societies Mill judges immature, which the argument never revisits.',
      es: 'Un argumento según el cual el único fundamento para coaccionar a un adulto es el daño a terceros, desarrollado en tres aplicaciones: la libertad de opinión, la libertad de plan de vida y los límites de lo que una sociedad puede imponer por la opinión y no por la ley. La dificultad del ensayo es su propia excepción para las sociedades que Mill juzga inmaduras, sobre la que el argumento nunca vuelve.',
    },
  },
  {
    work: 'demo-w-wollstonecraft-vindication',
    text: {
      en: 'A response to the educational programme of Rousseau’s Émile, arguing that the intellectual weakness attributed to women is produced by the education prescribed for them. The claim advanced is self-command rather than power over men, which allows the argument to accept its opponents’ observations while rejecting their explanation.',
      es: 'Una respuesta al programa educativo del Emilio de Rousseau que sostiene que la debilidad intelectual atribuida a las mujeres la produce la educación que se les prescribe. Lo que se reclama es dominio de sí y no poder sobre los hombres, lo que permite aceptar las observaciones de los adversarios y rechazar su explicación.',
    },
  },
  {
    work: 'demo-w-tocqueville-democracy',
    text: {
      en: 'The second volume turns from institutions to habits, and finds in equality a tendency to withdraw from public life that it names individualism. Its most cited chapters describe a form of despotism that is administrative rather than violent and that citizens consent to because it is comfortable.',
      es: 'El segundo volumen pasa de las instituciones a las costumbres y encuentra en la igualdad una tendencia a retirarse de la vida pública que llama individualismo. Sus capítulos más citados describen un despotismo administrativo antes que violento, al que los ciudadanos consienten porque resulta cómodo.',
    },
  },
  {
    work: 'demo-w-dubois-souls',
    text: {
      en: 'Fourteen essays on the position of Black Americans after Reconstruction, framed by the claim that the century’s defining problem is the colour line. Its central construct, double consciousness, describes a self formed by being seen through the eyes of a hostile world, and is offered as a measurement of that world rather than of the person.',
      es: 'Catorce ensayos sobre la situación de los afroamericanos tras la Reconstrucción, enmarcados por la tesis de que el problema que define el siglo es la línea de color. Su constructo central, la doble conciencia, describe un yo formado por ser visto con los ojos de un mundo hostil, y se ofrece como medida de ese mundo antes que de la persona.',
    },
  },
  {
    work: 'demo-w-smith-wealth',
    text: {
      en: 'An account of how the division of labour produces wealth, and — in the fifth book, far from where it is usually quoted — of what that same division does to the understanding of the person who works under it. The remedy proposed there is publicly funded compulsory schooling.',
      es: 'Una explicación de cómo la división del trabajo produce riqueza y —en el libro quinto, lejos de donde suele citarse— de lo que esa misma división le hace al entendimiento de quien trabaja bajo ella. El remedio que allí se propone es la escolarización obligatoria financiada con fondos públicos.',
    },
  },
];

const NOTE_FOLDERS = [
  {
    id: 'demo-nf-reading',
    name: { en: 'Reading notes', es: 'Notas de lectura' },
    summary: {
      en: 'What each work was actually arguing, in my own words.',
      es: 'Qué sostenía realmente cada obra, con mis palabras.',
    },
  },
  {
    id: 'demo-nf-questions',
    name: { en: 'Open questions', es: 'Preguntas abiertas' },
    summary: {
      en: 'Things the corpus does not settle.',
      es: 'Lo que el corpus no resuelve.',
    },
  },
];

const NOTES = [
  {
    id: 'demo-n-1',
    folder: 'demo-nf-reading',
    title: {
      en: 'Mill and Tocqueville are not saying the same thing',
      es: 'Mill y Tocqueville no dicen lo mismo',
    },
    content: {
      en: 'Mill takes "tyranny of the majority" from Tocqueville and changes what it is a tyranny over. For Tocqueville the victim is a political minority and the danger is administrative; for Mill it is the eccentric individual and the danger is social opinion.\n\nThat difference decides the remedy. Tocqueville wants associations and local government — institutions that give people something to do together. Mill wants a habit of tolerating oddity, which no institution can be built to supply.',
      es: 'Mill toma de Tocqueville la «tiranía de la mayoría» y cambia sobre qué se ejerce esa tiranía. Para Tocqueville la víctima es una minoría política y el peligro es administrativo; para Mill es el individuo excéntrico y el peligro es la opinión social.\n\nEsa diferencia decide el remedio. Tocqueville quiere asociaciones y gobierno local: instituciones que den a la gente algo que hacer en común. Mill quiere una costumbre de tolerar la rareza, y ninguna institución puede construirse para suministrarla.',
    },
  },
  {
    id: 'demo-n-2',
    folder: 'demo-nf-reading',
    title: {
      en: 'The two Adam Smiths are one Adam Smith',
      es: 'Los dos Adam Smith son un solo Adam Smith',
    },
    content: {
      en: 'Book I is quoted to prove that self-interest suffices. Book V says the arrangement that self-interest builds makes the labourer "as stupid and ignorant as it is possible for a human creature to become", and proposes compulsory public education to repair it.\n\nThe two are not in tension for Smith: a system can be the best available way of producing wealth and still owe a debt to the people it uses. Reading either half alone is what produces the contradiction.',
      es: 'El libro I se cita para probar que el interés propio basta. El libro V dice que el arreglo que el interés propio construye vuelve al trabajador «tan estúpido e ignorante como es posible que llegue a ser una criatura humana», y propone enseñanza pública obligatoria para repararlo.\n\nPara Smith no hay tensión: un sistema puede ser el mejor modo disponible de producir riqueza y aun así tener una deuda con la gente a la que usa. La contradicción la produce leer solo una de las dos mitades.',
    },
  },
  {
    id: 'demo-n-3',
    folder: 'demo-nf-questions',
    title: {
      en: 'Can the harm principle name exclusion?',
      es: '¿Puede el principio del daño llamar daño a la exclusión?',
    },
    content: {
      en: 'Du Bois describes a harm that is done by no identifiable act: being seen through the eyes of a world that despises you. Mill’s principle needs an agent and an injury.\n\nEither the principle is broader than its examples — in which case a great deal of ordinary social life is coercion — or it cannot reach the thing Du Bois is describing at all. The corpus does not settle this, which is why it is a gap and not an idea.',
      es: 'Du Bois describe un daño que no comete ningún acto identificable: ser visto con los ojos de un mundo que te desprecia. El principio de Mill necesita un agente y una lesión.\n\nO el principio es más amplio que sus ejemplos —y entonces buena parte de la vida social corriente es coacción— o no alcanza en absoluto lo que Du Bois describe. El corpus no lo resuelve, y por eso es un hueco y no una idea.',
    },
  },
  {
    id: 'demo-n-4',
    folder: 'demo-nf-questions',
    title: {
      en: 'Where Darwin does not belong',
      es: 'Dónde no encaja Darwin',
    },
    content: {
      en: 'Origin is here because the corpus keeps reaching for words like "development" and "progress", and Darwin is where the century got its confidence that history has a direction.\n\nHe says nothing about societies. The edge to Rousseau is inferred and weak on purpose: it marks a resemblance the corpus keeps drawing rather than a claim either author makes.',
      es: 'El Origen está aquí porque el corpus recurre una y otra vez a palabras como «desarrollo» y «progreso», y Darwin es de donde el siglo sacó su confianza en que la historia tiene una dirección.\n\nÉl no dice nada sobre sociedades. La arista hacia Rousseau es inferida y débil a propósito: marca un parecido que el corpus traza continuamente, no una tesis que ninguno de los dos autores sostenga.',
    },
  },
];

const COLLECTIONS = [
  { key: 'demo-c-core', name: { en: 'Core readings', es: 'Lecturas centrales' }, parent: null },
  { key: 'demo-c-education', name: { en: 'Education debate', es: 'La polémica educativa' }, parent: 'demo-c-core' },
  { key: 'demo-c-context', name: { en: 'Nineteenth-century context', es: 'Contexto decimonónico' }, parent: null },
];

const COLLECTION_MEMBERS = [
  ['demo-c-core', 'demo-w-mill-liberty'],
  ['demo-c-core', 'demo-w-dubois-souls'],
  ['demo-c-core', 'demo-w-tocqueville-democracy'],
  ['demo-c-education', 'demo-w-wollstonecraft-vindication'],
  ['demo-c-education', 'demo-w-rousseau-emile'],
  ['demo-c-context', 'demo-w-smith-wealth'],
  ['demo-c-context', 'demo-w-marx-manifesto'],
  ['demo-c-context', 'demo-w-darwin-origin'],
  ['demo-c-context', 'demo-w-kant-enlightenment'],
  ['demo-c-context', 'demo-w-thoreau-disobedience'],
];

/**
 * Fill a freshly migrated vault with the corpus above, in one language.
 *
 * Written as explicit INSERTs against the real schema rather than as a JSON document handed
 * straight to the app: a column this file names and the schema no longer has stops the build
 * here, loudly, instead of shipping a snapshot that draws an empty screen.
 */
export function seedDemoVault(db, locale) {
  if (!LOCALES.includes(locale)) throw new Error(`No demo corpus for "${locale}"`);
  const insert = (sql) => db.prepare(sql);

  const work = insert(`
    INSERT INTO works (nodus_id, title, authors_json, year, item_type, read_tag, notes,
                       light_status, deep_status, summary_status, source_type)
    VALUES (?, ?, ?, ?, ?, ?, ?, 'done', 'done', 'done', 'demo')
  `);
  const author = insert('INSERT INTO authors (author_id, name, canonical_key) VALUES (?, ?, ?)');
  const workAuthor = insert('INSERT INTO work_authors (nodus_id, author_id, role) VALUES (?, ?, ?)');
  const authorRelation = insert('INSERT INTO author_relations (from_author, to_author, type, weight) VALUES (?, ?, ?, ?)');
  const theme = insert('INSERT INTO themes (theme_id, label, created_at, pinned) VALUES (?, ?, ?, ?)');
  const workTheme = insert('INSERT INTO work_themes (nodus_id, theme_id) VALUES (?, ?)');
  const idea = insert('INSERT INTO ideas (global_id, type, label, statement, created_at) VALUES (?, ?, ?, ?, ?)');
  const occurrence = insert('INSERT INTO idea_occurrences (global_id, nodus_id, role, development, confidence) VALUES (?, ?, ?, ?, ?)');
  const themeLink = insert('INSERT INTO idea_theme_links (nodus_id, global_id, theme_id, confidence, basis) VALUES (?, ?, ?, ?, ?)');
  const evidence = insert('INSERT INTO evidence (id, global_id, nodus_id, quote, location, kind) VALUES (?, ?, ?, ?, ?, ?)');
  const edge = insert('INSERT INTO edges (id, from_id, to_id, type, basis, confidence, source_work) VALUES (?, ?, ?, ?, ?, ?, ?)');
  const gap = insert('INSERT INTO gaps (id, nodus_id, related_idea, kind, statement, confidence) VALUES (?, ?, ?, ?, ?, ?)');
  const passage = insert(`
    INSERT INTO passages (passage_id, nodus_id, chunk_index, text, page_label, char_len, content_hash, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const summary = insert(`
    INSERT INTO work_summaries (nodus_id, summary, source_level, content_hash, created_at, updated_at)
    VALUES (?, ?, 'deep', ?, ?, ?)
  `);
  const folder = insert('INSERT INTO note_folders (id, parent_id, name, order_idx, created_at, updated_at, summary) VALUES (?, NULL, ?, ?, ?, ?, ?)');
  const note = insert('INSERT INTO notes (id, folder_id, title, kind, content, order_idx, created_at, updated_at) VALUES (?, ?, ?, \'markdown\', ?, ?, ?, ?)');
  const collection = insert('INSERT INTO collections (collection_key, name, parent_key) VALUES (?, ?, ?)');
  const collectionMember = insert('INSERT INTO work_collections (nodus_id, collection_key) VALUES (?, ?)');

  const seed = db.transaction(() => {
    for (const entry of WORKS) {
      work.run(entry.id, entry.title, JSON.stringify(entry.authors), entry.year, entry.type, entry.read ? 1 : 0, t(entry.note, locale));
    }
    for (const entry of AUTHORS) {
      author.run(entry.id, entry.name, entry.name.toLowerCase().replace(/[^a-z]+/g, '-'));
      for (const nodusId of entry.works) workAuthor.run(nodusId, entry.id, 'author');
    }
    for (const entry of AUTHOR_RELATIONS) {
      authorRelation.run(entry.from, entry.to, entry.type, entry.weight);
    }
    for (const entry of THEMES) theme.run(entry.id, t(entry.label, locale), AT, entry.pinned);

    // A theme belongs to the works its ideas occur in; deriving it here rather than listing it
    // keeps `work_themes` true after an idea is moved.
    const workThemePairs = new Set();
    for (const entry of IDEAS) workThemePairs.add(`${entry.work} ${entry.theme}`);
    for (const link of EXTRA_THEME_LINKS) {
      const source = IDEAS.find((entry) => entry.id === link.idea);
      if (source) workThemePairs.add(`${source.work} ${link.theme}`);
    }
    for (const pair of [...workThemePairs].sort()) {
      const [nodusId, themeId] = pair.split(' ');
      workTheme.run(nodusId, themeId);
    }

    for (const entry of IDEAS) {
      idea.run(entry.id, entry.type, t(entry.label, locale), t(entry.statement, locale), AT);
      occurrence.run(entry.id, entry.work, entry.role, t(entry.development, locale), entry.confidence);
      themeLink.run(entry.work, entry.id, entry.theme, entry.confidence, 'explicit');
      evidence.run(
        `demo-ev-${entry.id.replace(/^demo-i-/, '')}`,
        entry.id,
        entry.work,
        entry.evidence.quote,
        entry.evidence.location,
        'explicit',
      );
    }
    for (const link of EXTRA_THEME_LINKS) {
      const source = IDEAS.find((entry) => entry.id === link.idea);
      if (!source) throw new Error(`Theme link names an idea that is not in the corpus: ${link.idea}`);
      themeLink.run(source.work, link.idea, link.theme, 0.6, 'inferred');
    }

    for (const entry of EDGES) {
      edge.run(entry.id, entry.from, entry.to, entry.type, entry.basis, entry.confidence, entry.work);
    }
    for (const entry of GAPS) {
      gap.run(entry.id, entry.work, entry.idea, entry.kind, t(entry.statement, locale), entry.confidence);
    }

    const chunkByWork = new Map();
    PASSAGES.forEach((entry, index) => {
      const chunk = chunkByWork.get(entry.work) ?? 0;
      chunkByWork.set(entry.work, chunk + 1);
      passage.run(
        `demo-p-${String(index + 1).padStart(3, '0')}`,
        entry.work,
        chunk,
        entry.text,
        entry.page,
        entry.text.length,
        hash(entry.text),
        AT,
      );
    });

    for (const entry of SUMMARIES) {
      const text = t(entry.text, locale);
      summary.run(entry.work, text, hash(text), AT, AT);
    }

    NOTE_FOLDERS.forEach((entry, index) => folder.run(entry.id, t(entry.name, locale), index, AT, AT, t(entry.summary, locale)));
    NOTES.forEach((entry, index) => note.run(entry.id, entry.folder, t(entry.title, locale), t(entry.content, locale), index, AT, AT));

    for (const entry of COLLECTIONS) collection.run(entry.key, t(entry.name, locale), entry.parent);
    for (const [key, nodusId] of COLLECTION_MEMBERS) collectionMember.run(nodusId, key);
  });

  seed();

  return {
    works: WORKS.length,
    ideas: IDEAS.length,
    passages: PASSAGES.length,
    edges: EDGES.length,
    debates: EDGES.filter((entry) => entry.type === 'contradicts' || entry.type === 'refutes').length,
  };
}
