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

type PlayerWinsMap = MapFlat<String, u32>;
type MatchesMap = Map<u64, Match>;
type PlayersMap = Map<String, MatchesMap>;

#[contract_state]
struct Leaderboard {
    #[flat] total_matches: i32,
    player_wins: PlayerWinsMap,
    players: PlayersMap,
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

    pub fn record_match(&mut self, player: String, match_id: u64, score: u16, opponent: String) {
        self.players.with_mut(player, |matches| {
            matches.with_mut(match_id, |m| {
                *m.score = score;
                *m.opponent = opponent;
            });
        });
        *self.total_matches += 1;
    }

    pub fn get_match_score(&mut self, player: String, match_id: u64) -> Vec<u8> {
        self.players.with_mut(player, |matches| {
            matches.with_mut(match_id, |m| {
                (*m.score).to_string().into_bytes()
            })
        })
    }

    pub fn get_match_opponent(&mut self, player: String, match_id: u64) -> String {
        self.players.with_mut(player, |matches| {
            matches.with_mut(match_id, |m| {
                (*m.opponent).clone()
            })
        })
    }

    pub fn set_tournament_info(&mut self, name: String, prize_pool: u64) {
        *self.tournament.name = name;
        *self.tournament.prize_pool = prize_pool;
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

    pub fn set_player_wins(&mut self, player: String, wins: u32) {
        self.player_wins.insert(player, wins);
    }
}
