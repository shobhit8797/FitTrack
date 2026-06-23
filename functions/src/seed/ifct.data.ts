// IFCT-style Indian food composition seed (spec §12). per100g macros ground the
// LLM's photo/text estimates (spec §7.3). dishKey must match the lowercase
// canonical key the food prompts ask the model to emit. typicalServingG is the
// usual katori/piece weight, used as a portion fallback.

export interface SeedFood {
  name: string;
  dishKey: string;
  per100g: { calories: number; proteinG: number; carbsG: number; fatG: number };
  typicalServingG: number;
}

export const IFCT_FOODS: SeedFood[] = [
  { name: 'Dal (cooked toor/arhar)', dishKey: 'dal', per100g: { calories: 116, proteinG: 6.4, carbsG: 16, fatG: 2.7 }, typicalServingG: 150 },
  { name: 'Rajma (kidney bean curry)', dishKey: 'rajma', per100g: { calories: 140, proteinG: 7.2, carbsG: 18, fatG: 4.1 }, typicalServingG: 180 },
  { name: 'Chana masala', dishKey: 'chana masala', per100g: { calories: 164, proteinG: 7.5, carbsG: 20, fatG: 6.0 }, typicalServingG: 180 },
  { name: 'Paneer butter masala', dishKey: 'paneer butter masala', per100g: { calories: 230, proteinG: 9.0, carbsG: 9, fatG: 18 }, typicalServingG: 180 },
  { name: 'Palak paneer', dishKey: 'palak paneer', per100g: { calories: 180, proteinG: 8.5, carbsG: 7, fatG: 13 }, typicalServingG: 180 },
  { name: 'Paneer tikka', dishKey: 'paneer tikka', per100g: { calories: 270, proteinG: 18, carbsG: 6, fatG: 19 }, typicalServingG: 120 },
  { name: 'Soya chunk curry', dishKey: 'soya curry', per100g: { calories: 170, proteinG: 14, carbsG: 12, fatG: 7 }, typicalServingG: 180 },
  { name: 'Tofu stir fry', dishKey: 'tofu', per100g: { calories: 144, proteinG: 12, carbsG: 4, fatG: 9 }, typicalServingG: 150 },
  { name: 'Mixed vegetable sabzi', dishKey: 'sabzi', per100g: { calories: 120, proteinG: 3.0, carbsG: 12, fatG: 7 }, typicalServingG: 150 },
  { name: 'Aloo gobi', dishKey: 'aloo gobi', per100g: { calories: 130, proteinG: 3.2, carbsG: 15, fatG: 7 }, typicalServingG: 150 },
  { name: 'Bhindi masala', dishKey: 'bhindi', per100g: { calories: 125, proteinG: 2.5, carbsG: 11, fatG: 8 }, typicalServingG: 150 },
  { name: 'Plain roti (chapati)', dishKey: 'roti', per100g: { calories: 297, proteinG: 9.0, carbsG: 56, fatG: 4.5 }, typicalServingG: 40 },
  { name: 'Tandoori roti', dishKey: 'tandoori roti', per100g: { calories: 285, proteinG: 8.5, carbsG: 55, fatG: 4.0 }, typicalServingG: 50 },
  { name: 'Plain paratha', dishKey: 'paratha', per100g: { calories: 330, proteinG: 7.0, carbsG: 45, fatG: 13 }, typicalServingG: 60 },
  { name: 'Steamed white rice', dishKey: 'rice', per100g: { calories: 130, proteinG: 2.7, carbsG: 28, fatG: 0.3 }, typicalServingG: 150 },
  { name: 'Jeera rice', dishKey: 'jeera rice', per100g: { calories: 170, proteinG: 3.0, carbsG: 30, fatG: 4.0 }, typicalServingG: 150 },
  { name: 'Vegetable biryani', dishKey: 'veg biryani', per100g: { calories: 165, proteinG: 4.0, carbsG: 27, fatG: 4.5 }, typicalServingG: 200 },
  { name: 'Plain dosa', dishKey: 'dosa', per100g: { calories: 168, proteinG: 3.9, carbsG: 30, fatG: 3.7 }, typicalServingG: 90 },
  { name: 'Masala dosa', dishKey: 'masala dosa', per100g: { calories: 190, proteinG: 4.2, carbsG: 30, fatG: 6.5 }, typicalServingG: 150 },
  { name: 'Idli', dishKey: 'idli', per100g: { calories: 130, proteinG: 4.0, carbsG: 26, fatG: 0.8 }, typicalServingG: 40 },
  { name: 'Sambar', dishKey: 'sambar', per100g: { calories: 85, proteinG: 3.5, carbsG: 12, fatG: 2.5 }, typicalServingG: 150 },
  { name: 'Curd / dahi (plain)', dishKey: 'curd', per100g: { calories: 60, proteinG: 3.1, carbsG: 4.7, fatG: 3.3 }, typicalServingG: 100 },
  { name: 'Raita', dishKey: 'raita', per100g: { calories: 70, proteinG: 2.8, carbsG: 5, fatG: 4 }, typicalServingG: 100 },
  { name: 'Poha', dishKey: 'poha', per100g: { calories: 150, proteinG: 2.6, carbsG: 27, fatG: 3.5 }, typicalServingG: 150 },
  { name: 'Upma', dishKey: 'upma', per100g: { calories: 160, proteinG: 3.5, carbsG: 25, fatG: 5.0 }, typicalServingG: 150 },
  { name: 'Boiled egg', dishKey: 'boiled egg', per100g: { calories: 155, proteinG: 13, carbsG: 1.1, fatG: 11 }, typicalServingG: 50 },
  { name: 'Egg curry', dishKey: 'egg curry', per100g: { calories: 165, proteinG: 9, carbsG: 6, fatG: 12 }, typicalServingG: 180 },
  { name: 'Chicken curry', dishKey: 'chicken curry', per100g: { calories: 180, proteinG: 16, carbsG: 5, fatG: 11 }, typicalServingG: 180 },
];
