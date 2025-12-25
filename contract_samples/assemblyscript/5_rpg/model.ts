import {
  Serializer,
  Deserializer,
  DecodeRef,
  decodeVarint,
  decodeString,
  decodeU16,
  decodeBytes,
  TYPE_MAP,
} from "../sdk_vecpak";

export class Hero {
  hp_cur: i16 = 20;
  hp_max: i16 = 20;
  str: u16 = 10;
  dex: u16 = 10;
  int: u16 = 10;
  weapon: string = "";
  helmet: string = "";

  serialize(): Uint8Array {
    const s = new Serializer();

    s.addI16("hp_cur", this.hp_cur);
    s.addI16("hp_max", this.hp_max);
    s.addU16("str", this.str);
    s.addU16("dex", this.dex);
    s.addU16("int", this.int);

    return s.finish();
  }

  static deserialize(data: Uint8Array): Hero {
    const d = new Deserializer(data);
    const hero = new Hero();

    while (d.hasNext()) {
      const key = d.nextKey();

      if (key == "hp_cur") {
        hero.hp_cur = d.readI16();
      } else if (key == "hp_max") {
        hero.hp_max = d.readI16();
      } else if (key == "str") {
        hero.str = d.readU16();
      } else if (key == "dex") {
        hero.dex = d.readU16();
      } else if (key == "int") {
        hero.int = d.readU16();
      } else {
        d.skip();
      }
    }

    return hero;
  }
}

export class Monster {
  hp_cur: i16 = 10;
  hp_max: i16 = 10;
  dam_min: u16 = 1;
  dam_max: u16 = 2;
  ac: u16 = 0;
  drop_table: Array<DropChance> = new Array<DropChance>();
  getDropTable(): StaticArray<DropChance> {
    return [];
  }
}

export class DropChance {
  constructor(
    public nft_id: string = "null",
    public chance: i32 = 0,
  ) {}
}

export class Goblin extends Monster {
  hp_cur: i16 = 10;
  hp_max: i16 = 10;
  dam_min: u16 = 1;
  dam_max: u16 = 2;
  ac: u16 = 0;
  static drop_table: StaticArray<DropChance> = [
    new DropChance("gold", 30),
    new DropChance("rusty_dagger", 5),
  ];
  getDropTable(): StaticArray<DropChance> {
    return Goblin.drop_table;
  }
}

export class Orc extends Monster {
  hp_cur: i16 = 18;
  hp_max: i16 = 18;
  dam_min: u16 = 1;
  dam_max: u16 = 3;
  ac: u16 = 1;
  static drop_table: StaticArray<DropChance> = [
    new DropChance("gold", 30),
    new DropChance("orc_helmet", 5),
  ];
  getDropTable(): StaticArray<DropChance> {
    return Orc.drop_table;
  }
}

export class Stats {
  dam_dice_sides: u16 = 0;
  dam_extra: u16 = 0;
  ac: u16 = 0;
  image_url: string = "";
}

export function view_item(nft_id: string): Stats {
  switch (nft_id) {
    case "gold":
      let stats = new Stats();
      stats.image_url =
        "https://ipfs.io/ipfs/QmWBaeu6y1zEcKbsEqCuhuDHPL3W8pZouCPdafMCRCSUWk";
      return stats;
    case "rusty_dagger":
      let stats = new Stats();
      stats.dam_dice_sides = 3;
      stats.dam_extra = 1;
      stats.image_url =
        "https://ipfs.io/ipfs/QmWBaeu6y1zEcKbsEqCuhuDHPL3W8pZouCPdafMCRCSUWk";
      return stats;
    case "orc_helmet":
      let stats = new Stats();
      stats.ac = 1;
      stats.image_url =
        "https://ipfs.io/ipfs/QmWBaeu6y1zEcKbsEqCuhuDHPL3W8pZouCPdafMCRCSUWk";
      return stats;
    default:
      let stats = new Stats();
      return stats;
  }
}
