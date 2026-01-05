#![no_std]
#![no_main]

extern crate alloc;
use alloc::vec::Vec;
use alloc::string::{String, ToString};
use amadeus_sdk::*;

#[contract_state]
struct Match {
    #[flat] score: u16,
    #[flat] opponent: String,
}

#[contract_state]
struct TournamentInfo {
    #[flat] name: String,
    #[flat] prize_pool: u64,
}

#[contract_state]
struct Leaderboard {
    #[flat] total_matches: i32,
    player_wins: Map<String, u32>,
    players: MapNested<String, MapNested<u64, Match>>,
    tournament: TournamentInfo,
}

#[contract]
impl Leaderboard {
    pub fn increment_total_matches(&mut self) {
        *self.total_matches += 1;
    }

    pub fn get_total_matches(&mut self) -> Vec<u8> {
        (*self.total_matches).to_string().into_bytes()
    }

    pub fn record_match(&mut self, player: String, match_id: Vec<u8>, score: Vec<u8>, opponent: String) {
        let match_id_u64 = u64::from_bytes(match_id);
        self.players.with_mut(player, |matches| {
            matches.with_mut(match_id_u64, |m| {
                *m.score = u16::from_bytes(score);
                *m.opponent = opponent;
            });
        });
        *self.total_matches += 1;
    }

    pub fn get_match_score(&mut self, player: String, match_id: Vec<u8>) -> Vec<u8> {
        let match_id_u64 = u64::from_bytes(match_id);
        self.players.with_mut(player, |matches| {
            matches.with_mut(match_id_u64, |m| {
                (*m.score).to_string().into_bytes()
            })
        })
    }

    pub fn get_match_opponent(&mut self, player: String, match_id: Vec<u8>) -> String {
        let match_id_u64 = u64::from_bytes(match_id);
        self.players.with_mut(player, |matches| {
            matches.with_mut(match_id_u64, |m| {
                (*m.opponent).clone()
            })
        })
    }

    pub fn set_tournament_info(&mut self, name: String, prize_pool: Vec<u8>) {
        *self.tournament.name = name;
        *self.tournament.prize_pool = u64::from_bytes(prize_pool);
    }

    pub fn get_tournament_name(&mut self) -> String {
        (*self.tournament.name).clone()
    }

    pub fn get_tournament_prize(&mut self) -> Vec<u8> {
        (*self.tournament.prize_pool).to_string().into_bytes()
    }

    pub fn record_win(&mut self, player: String) {
        if let Some(wins) = self.player_wins.get_mut(&player) {
            **wins += 1;
        } else {
            self.player_wins.insert(player, 1);
        }
    }

    pub fn get_player_wins(&mut self, player: String) -> Vec<u8> {
        if let Some(wins) = self.player_wins.get(&player) {
            (*wins).to_string().into_bytes()
        } else {
            "0".to_string().into_bytes()
        }
    }

    pub fn set_player_wins(&mut self, player: String, wins: Vec<u8>) {
        self.player_wins.insert(player, u32::from_bytes(wins));
    }
}
