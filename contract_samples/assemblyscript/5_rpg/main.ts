import * as sdk from "../sdk";
import { b, bcat, b58 } from "../sdk";
import { Monster, Goblin, Orc, Hero, view_item } from "./model";

export function view_nft(): void {}

export function init(): void {
  sdk.log("RPG Inited");
  sdk.call("Nft", "create_collection", [b("RPG"), b("false")]);
  sdk.call("Nft", "create_collection", [b("RPGSOULBOUND"), b("true")]);
}

export function create_hero(): void {
  const new_hero = new Hero();

  const key = bcat([b("hero:"), sdk.account_caller()]);
  assert(!sdk.kv_exists(key), "hero exists");

  sdk.kv_put(key, new_hero.serialize());
}

export function fight(): void {
  // load hero
  const hero_key = bcat([b("hero:"), sdk.account_caller()]);
  const hero_bytes = sdk.kv_get(hero_key);
  assert(hero_bytes, "hero doesnt exist");
  let hero = Hero.deserialize(hero_bytes!);

  // random monster encounter
  const monster_dice = roll_dice(10);
  let monster: Monster = new Goblin();
  if (monster_dice >= 7) {
    monster = new Orc();
  }

  // FIGHT!
  while (1) {
    if (hero.hp_cur <= 0) {
      sdk.log("You have died, reviving");
      hero.hp_cur = hero.hp_max;
      sdk.kv_put(hero_key, hero.serialize());
      break;
    }
    if (monster.hp_cur <= 0) {
      sdk.log("Monster died");
      let dropTable = monster.getDropTable();
      for (let i = 0; i < dropTable.length; i++) {
        let item = dropTable[i];
        let roll = roll_dice(100);
        if (roll <= item.chance) {
          sdk.log(`Monster dropped a ${item.nft_id}`);
          sdk.call("Nft", "mint", [sdk.account_caller(), b("1"), b("RPG"), b(item.nft_id)])
        }
      }
      break;
    }

    let weapon_stats = view_item(hero.weapon);
    let helmet_stats = view_item(hero.helmet);
    let hero_attack_roll =
      roll_dice(weapon_stats.dam_dice_sides) + weapon_stats.dam_extra;
    let hero_ac = helmet_stats.ac;

    let monster_attack_dice = roll_dice(monster.dam_max) + monster.dam_min;

    let hero_damage_taken = monster_attack_dice - hero_ac;
    let monster_damage_taken = hero_attack_roll - monster.ac;

    hero.hp_cur -= hero_damage_taken as i16;
    monster.hp_cur -= monster_damage_taken as i16;

    sdk.log(`You hit monster for ${monster_damage_taken}, mob HP is ${monster.hp_cur}/${monster.hp_max}.`);
    sdk.log(`Monster hit you for ${hero_damage_taken}, your HP is ${hero.hp_cur}/${hero.hp_max}.`);
  }
}

export function roll_dice(sides: u32): i64 {
  const val = Math.random(); // Returns 0.0 to 1.0
  return (floor(val * sides) as i32) + 1; // Returns 1-sides
}
