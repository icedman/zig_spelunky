//! GameMaker virtual key codes (the browser keyCode values the HTML5 runner
//! uses, yyIOManager.js). Hosts translate their native keys / buttons to
//! these; letters and digits are their upper-case ASCII codes.

pub const vk_backspace: i32 = 8;
pub const vk_tab: i32 = 9;
pub const vk_enter: i32 = 13;
pub const vk_shift: i32 = 16;
pub const vk_control: i32 = 17;
pub const vk_alt: i32 = 18;
pub const vk_pause: i32 = 19;
pub const vk_escape: i32 = 27;
pub const vk_space: i32 = 32;
pub const vk_pageup: i32 = 33;
pub const vk_pagedown: i32 = 34;
pub const vk_end: i32 = 35;
pub const vk_home: i32 = 36;
pub const vk_left: i32 = 37;
pub const vk_up: i32 = 38;
pub const vk_right: i32 = 39;
pub const vk_down: i32 = 40;
pub const vk_insert: i32 = 45;
pub const vk_delete: i32 = 46;
pub const vk_numpad0: i32 = 96;
pub const vk_f1: i32 = 112;

/// Host debug key: spawns the --item object (App.Options.item_object).
pub const vk_debug_item: i32 = 'O';
