// SPDX-License-Identifier: Not licensed
// OpenZeppelin Contracts for Cairo v0.7.0 (token/erc721/erc721.cairo)

// When `LegacyMap` is called with a non-existent key, it returns a struct with all properties are initialized to zero values.

use starknet::ContractAddress;
use starknet::contract_address_const;
use openzeppelin::token::erc20::interface::IERC20CamelDispatcher;

// Todo: replace with mainnet fee contract's address.
fn fee_contract() -> IFeeContractDispatcher {
    IFeeContractDispatcher {
        contract_address: contract_address_const::<
            0x06c9d1282ed21578d54bd1ea909b155bdd1290ef69f52b9e3950d2c77c7eb6dc
        >(),
    }
}

fn eth_contract() -> IERC20CamelDispatcher {
    IERC20CamelDispatcher {
        contract_address: contract_address_const::<
            0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
        >(),
    }
}

// The remote contract that manages launchpad fees.
#[starknet::interface]
trait IFeeContract<TContractState> {
    fn get_owner(self: @TContractState) -> ContractAddress;
    fn get_deploy_fee_and_owner(self: @TContractState) -> (u256, ContractAddress);
    fn set_owner(ref self: TContractState, new_owner: ContractAddress);
    fn set_deploy_fee(ref self: TContractState, deployFee: u256);
    fn set_custom_fee(ref self: TContractState, collection_addr: ContractAddress, ethFee: u256, strkFee: u256);
    fn set_default_fee(ref self: TContractState, ethFee: u256, strkFee: u256);
    fn get_fee_and_owner(
        self: @TContractState, collection_addr: ContractAddress
    ) -> (u256, u256, ContractAddress);
}

#[starknet::contract]
mod PyramidLaunchpad {
    use core::option::OptionTrait;
use core::array::ArrayTrait;
    use core::traits::Destruct;
    use core::traits::TryInto;
    use core::traits::Into;
    use core::clone::Clone;
    use integer::{u256_from_felt252, U64IntoFelt252};
    use super::{IFeeContractDispatcherTrait, fee_contract, eth_contract};
    use starknet::ContractAddress;
    use starknet::{
        get_caller_address, get_block_timestamp, get_contract_address, contract_address_const
    };
    use core::bool;
    use core::Zeroable;
    use openzeppelin::account;
    use openzeppelin::access::ownable;

    use pyramidlp::introspection::dual_src5::DualCaseSRC5;
    use pyramidlp::introspection::dual_src5::DualCaseSRC5Trait;
    use pyramidlp::introspection::interface::ISRC5;
    use pyramidlp::introspection::interface::ISRC5Camel;
    use pyramidlp::introspection::src5;
    use pyramidlp::introspection::interface::{ISRC5Dispatcher, ISRC5DispatcherTrait};

    use openzeppelin::token::erc721::dual721_receiver::DualCaseERC721Receiver;
    use openzeppelin::token::erc721::dual721_receiver::DualCaseERC721ReceiverTrait;
    use openzeppelin::token::erc721::interface;
    use pyramidlp::interface::IERC721Enumerable::IERC721CamelOnly;
    use openzeppelin::token::erc20::interface::IERC20CamelDispatcherTrait;
    use openzeppelin::token::erc20::interface::IERC20CamelDispatcher;

    #[storage]
    struct Storage {
        _name: felt252, // e.g. BoredApeYachtClub 
        _symbol: felt252, // e.g. BAYC
        _owners: LegacyMap<u256, ContractAddress>,
        _balances: LegacyMap<ContractAddress, u256>,
        _token_approvals: LegacyMap<u256, ContractAddress>,
        _operator_approvals: LegacyMap<(ContractAddress, ContractAddress), bool>,
        _owner: ContractAddress,
        _base_uri_parts: LegacyMap<u8, felt252>,
        _base_uri_suffix: felt252,
        _max_supply: u256,
        _total_supply: u256,
        _general_start_time: u64,
        _general_end_time: u64,
        _rounds: LegacyMap<u8, Round>,
        _users_wl: LegacyMap<(ContractAddress, u8), bool>,
        _total_minted: u256,
        _users_minted_count: LegacyMap<(ContractAddress, u8), u32>,
        _user_total_minted_count: LegacyMap<ContractAddress, u256>,
        _users_minted_tokens: LegacyMap<(ContractAddress, u256), u256>,
        _reentrancy_guard_entered: bool,
        _is_initialized: bool,
        isCurrencyEth: bool,
        _isCancelled: bool,
    }


    #[derive(Drop, starknet::Store, Serde, Copy)]
    struct Round {
        is_public: bool,
        start_time: u64,
        end_time: u64,
        price: u256,
        mint_limit: u32,
        max_supply: u256,
        minted_supply: u256,
    }

    impl RoundZeroable of Zeroable<Round> {
        fn zero() -> Round {
            Round {
                is_public: false,
                start_time: 0,
                end_time: 0,
                price: 0,
                mint_limit: 0,
                max_supply: 0,
                minted_supply: 0,
            }
        }

        fn is_zero(self: Round) -> bool {
            self.end_time.is_zero()
        }

        fn is_non_zero(self: Round) -> bool {
            !self.is_zero()
        }
    }

    

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Transfer: Transfer,
        Approval: Approval,
        ApprovalForAll: ApprovalForAll,
        OwnershipTransferred: OwnershipTransferred,
        SaleInitialized: SaleInitialized,
    }

    #[derive(Drop, starknet::Event)]
    struct SaleInitialized {
        address: ContractAddress,
        time: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct OwnershipTransferred {
        previous_owner: ContractAddress,
        new_owner: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        from: ContractAddress,
        to: ContractAddress,
        token_id: u256
    }

    #[derive(Drop, starknet::Event)]
    struct Approval {
        owner: ContractAddress,
        approved: ContractAddress,
        token_id: u256
    }

    #[derive(Drop, starknet::Event)]
    struct ApprovalForAll {
        owner: ContractAddress,
        operator: ContractAddress,
        approved: bool
    }

    mod Errors {
        const INVALID_TOKEN_ID: felt252 = 'ERC721: invalid token ID';
        const INVALID_ACCOUNT: felt252 = 'ERC721: invalid account';
        const UNAUTHORIZED: felt252 = 'ERC721: unauthorized caller';
        const APPROVAL_TO_OWNER: felt252 = 'ERC721: approval to owner';
        const SELF_APPROVAL: felt252 = 'ERC721: self approval';
        const INVALID_RECEIVER: felt252 = 'ERC721: invalid receiver';
        const ALREADY_MINTED: felt252 = 'ERC721: token already minted';
        const WRONG_SENDER: felt252 = 'ERC721: wrong sender';
        const SAFE_MINT_FAILED: felt252 = 'ERC721: safe mint failed';
        const SAFE_TRANSFER_FAILED: felt252 = 'ERC721: safe transfer failed';
        const REENTRANT_CALL: felt252 = 'ReentrancyGuard: reentrant call';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        symbol: felt252,
        owner: ContractAddress,
        max_supply: felt252,
        base_uri_parts: Array<felt252>,
        base_uri_suffix: felt252,
    ) {
        self.initializer(name, symbol);
        self._owner.write(owner);
        self._max_supply.write(max_supply.into());
        self._set_base_uri_parts(base_uri_parts);
        self._base_uri_suffix.write(base_uri_suffix);
    }

    //
    // External
    //

    #[external(v0)]
    impl SRC5Impl of ISRC5Camel<ContractState> {
        fn supportsInterface(self: @ContractState, interfaceId: felt252) -> bool {
            let unsafe_state = src5::SRC5::unsafe_new_contract_state();
            src5::SRC5::SRC5Impl::supports_interface(@unsafe_state, interfaceId)
        }
    }

    #[starknet::interface]
    trait IERC721MetadataFeltArray<TState> {
        fn name(self: @TState) -> felt252;
        fn symbol(self: @TState) -> felt252;
        fn tokenUri(self: @TState, token_id: u256) -> Array<felt252>;
    }

    #[external(v0)]
    impl ERC721MetadataImpl of IERC721MetadataFeltArray<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self._name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self._symbol.read()
        }

        fn tokenUri(self: @ContractState, token_id: u256) -> Array<felt252> {
            assert(self._exists(token_id), Errors::INVALID_TOKEN_ID);
            self._token_uri(token_id)
        }
    }

    #[external(v0)]
    impl ERC721Impl of IERC721CamelOnly<ContractState> {
        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            assert(!account.is_zero(), Errors::INVALID_ACCOUNT);
            self._balances.read(account)
        }
        fn totalSupply(self: @ContractState) -> u256 {
            self._total_supply.read()
        }

        fn maxSupply(self: @ContractState) -> u256 {
            self._max_supply.read()
        }

        fn ownerOf(self: @ContractState, tokenId: u256) -> ContractAddress {
            self._owner_of(tokenId)
        }

        fn getApproved(self: @ContractState, tokenId: u256) -> ContractAddress {
            assert(self._exists(tokenId), Errors::INVALID_TOKEN_ID);
            self._token_approvals.read(tokenId)
        }

        fn isApprovedForAll(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            self._operator_approvals.read((owner, operator))
        }


        fn setApprovalForAll(ref self: ContractState, operator: ContractAddress, approved: bool) {
            self._set_approval_for_all(get_caller_address(), operator, approved)
        }

        fn transferFrom(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, tokenId: u256
        ) {
            assert(
                self._is_approved_or_owner(get_caller_address(), tokenId), Errors::UNAUTHORIZED,
            );
            self._transfer(from, to, tokenId);
        }

        fn safeTransferFrom(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            tokenId: u256,
            data: Span<felt252>,
        ) {
            assert(
                self._is_approved_or_owner(get_caller_address(), tokenId), Errors::UNAUTHORIZED,
            );
            self._safe_transfer(from, to, tokenId, data);
        }
    }

    #[external(v0)]
    fn approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
        let owner = self._owner_of(token_id);

        let caller = get_caller_address();
        assert(
            owner == caller || ERC721Impl::isApprovedForAll(@self, owner, caller),
            Errors::UNAUTHORIZED,
        );
        self._approve(to, token_id);
    }

    #[starknet::interface]
    trait NFT<TState> {
        fn mint(ref self: TState, round_id: u8, amount: u32);
        fn cancelSale(ref self: TState);
        fn collect_revenue(ref self: TState);
        fn refund(ref self: TState);
        fn burn(ref self: TState, tokenId: u256);
        fn get_status(self: @TState) -> felt252;
        fn get_round(self: @TState, roundId : u8) -> Round;
        fn get_user_minted_count(self: @TState, userAddr: ContractAddress, roundId: u8) -> u32;
        fn get_rounds(self: @TState) -> Array<Round>;
        fn has_wl(self: @TState, round_id: u8, addr: ContractAddress) -> bool;
        fn can_get_refunded(self: @TState, addr: ContractAddress) -> bool;
        fn can_collect_revenue(self: @TState, addr: ContractAddress) -> bool;
        fn add_round(
            ref self: TState,
            round_id: u8,
            is_public: bool,
            start_time: u64,
            end_time: u64,
            price: u256,
            mint_limit: u32,
            max_supply: u256
        );
        fn add_wl(ref self: TState, round_id: u8, wl_addresses: Array<ContractAddress>, _status: bool);
        fn set_base_uri_parts(ref self: TState, new_base_uri_parts: Array<felt252>);
        fn set_base_uri_suffix(ref self: TState, base_uri_suffix: felt252);
        fn set_initialized(ref self: TState);
        fn is_initialized(self: @TState) -> bool;
        fn setCurrency(ref self: TState, _isCurrencyEth: bool);
    }

    #[derive(Drop, PartialEq, Copy)]
    enum Status {
        Upcoming, // 0
        Ongoing, // 1
        Finished, // 2
        Refundable, // 3
    }

    #[external(v0)]
    impl NFTImpl of NFT<ContractState> {
        fn set_base_uri_suffix(ref self: ContractState, base_uri_suffix: felt252) {
            self.assert_only_owner();

            self._base_uri_suffix.write(base_uri_suffix);
        }

        fn cancelSale(ref self: ContractState) {
            self.assert_only_owner();
            assert(self._get_status() == Status::Upcoming, 'stage must be upcoming');
            assert(self._isCancelled.read() == false, 'already cancelled');
            self._isCancelled.write(true);
        }

        fn is_initialized(self: @ContractState) -> bool {
            self._is_initialized.read()
        }

        fn set_initialized(ref self: ContractState) {
            self.assert_only_owner();
            let caller = get_caller_address();
            let this = get_contract_address();
            let now = get_block_timestamp();
            let feeContract = fee_contract();
            let (ethFee, fee_receiver) = feeContract.get_deploy_fee_and_owner();
            let _eth_contract = eth_contract();
            _eth_contract.transferFrom(caller, fee_receiver, ethFee);
            self._is_initialized.write(true);
            self.emit(
                    SaleInitialized { address: this, time: now }
                );
        }

        fn burn(
            ref self: ContractState, tokenId: u256
        ) {
            let owner = self._owner_of(tokenId);
            let caller = get_caller_address();
            assert(!caller.is_zero(), 'Caller is the zero address');
            assert(owner == caller, Errors::UNAUTHORIZED);

            self._burn(tokenId);
        }

         fn setCurrency(ref self: ContractState, _isCurrencyEth: bool) {
            self.assert_only_owner();
            assert(self._is_initialized.read() == false, 'Launch is initialized');

            self.isCurrencyEth.write(_isCurrencyEth);
        }

        fn has_wl(self: @ContractState, round_id: u8, addr: ContractAddress) -> bool {
            self._users_wl.read((addr, round_id))
        }

        fn can_get_refunded(self: @ContractState, addr: ContractAddress) -> bool {
            assert(self._get_status() == Status::Refundable, 'Launch status is not refundable');

            let mut can_get_refunded = false;

            let mut i: u8 = 0;

            loop {
                let round = self._rounds.read(i);
                if round.is_zero() {
                    break;
                }

                let mint_count = self._users_minted_count.read((addr, i));
                if mint_count.is_non_zero() {
                    can_get_refunded = true;
                    break;
                };

                i += 1;
            };

            can_get_refunded
        }

        fn can_collect_revenue(self: @ContractState, addr: ContractAddress) -> bool {
            assert(self._get_status() == Status::Finished, 'Launch status is not finished');
            
            let eth_contract = self.currency_contract();
            let contract_addr = get_contract_address();
            let balance = eth_contract.balanceOf(contract_addr);
            assert(!balance.is_zero(), 'funds already withdrawed');
            assert(self._owner.read() == addr, 'must be owner');
            return bool::True;          
        }


        fn add_round(
            ref self: ContractState,
            round_id: u8,
            is_public: bool,
            start_time: u64,
            end_time: u64,
            price: u256,
            mint_limit: u32,
            max_supply: u256
        ) {
            self.assert_only_owner();
  
            assert(self._is_initialized.read() == false, 'Launch is initialized');
            assert(end_time - start_time < 432000, 'too much difference');
            // we set 5 mins before of actual start time as block timestamp might delayed.
            let modifiedStartTime : u64 = start_time - 300;
            let round = Round {
                is_public, start_time: modifiedStartTime, end_time, price, mint_limit, max_supply, minted_supply: 0,
            };
            self._rounds.write(round_id, round);

        }

        fn set_base_uri_parts(ref self: ContractState, new_base_uri_parts: Array<felt252>) {
            self.assert_only_owner();

            self._set_base_uri_parts(new_base_uri_parts);
        }

        fn add_wl(ref self: ContractState, round_id: u8, wl_addresses: Array<ContractAddress>, _status: bool) {
            self.assert_only_owner();

            let status = self._get_status();
            assert(status == Status::Upcoming, 'Whitelist cannot be set anymore');

            let mut i: u32 = 0;

            loop {
                if i == wl_addresses.len() {
                    break;
                };

                let addr = wl_addresses.at(i).clone();

                self._users_wl.write((addr, round_id), _status);

                i += 1;
            }
        }

        fn get_status(self: @ContractState) -> felt252 {
            match self._get_status() {
                Status::Upcoming => 'Upcoming',
                Status::Ongoing => 'Ongoing',
                Status::Finished => 'Finished',
                Status::Refundable => 'Refundable',
            }
        }

        fn get_user_minted_count(self: @ContractState, userAddr: ContractAddress, roundId: u8) -> u32 {
            self._users_minted_count.read((userAddr, roundId))
        }
        
        
        fn get_round(self: @ContractState, roundId: u8) -> Round {
           self._rounds.read(roundId)
        }

        fn get_rounds(self: @ContractState) -> Array<Round> {
            let mut i: u8 = 0;

            let mut rounds = ArrayTrait::<Round>::new();

            loop {
                let round = self._rounds.read(i);

                if round.is_zero() {
                    break;
                }
                rounds.append(round);
                i += 1;
            };

            rounds
        }

        fn mint(ref self: ContractState, round_id: u8, amount: u32) {
            assert(self._is_initialized.read() == true, 'must be initialized');

            let caller = get_caller_address();
            let collection_addr = get_contract_address();
            let timestamp = get_block_timestamp();

            let mut round = self._rounds.read(round_id);
            assert(round.is_non_zero(), 'Round does not exist');
            let status = self._get_status();
            assert(status == Status::Ongoing, 'woot! minting is not available.');

            assert(timestamp > round.start_time, 'Round has not started yet');
            assert(timestamp < round.end_time, 'Round is ended');
            
            assert(self._total_minted.read() + amount.into() <= self._max_supply.read(), 'cant mint more than max supply'); 
            let minted_count = self._users_minted_count.read((caller, round_id));

            if !round.is_public {
                let has_wl = self._users_wl.read((caller, round_id));
                assert(has_wl, 'You are not in WL list');
            }

            assert(amount != 0, 'Mint amount is zero');
            assert(minted_count + amount <= round.mint_limit, 'Mint limit is exceeded');
            assert(
                round.minted_supply + amount.into() <= round.max_supply, 'Mint amount is invalid 1'
            );
            assert(
                round.minted_supply + amount.into() <= self._max_supply.read(),
                'Mint amount is invalid 2'
            );

            let fee_contract = fee_contract();

            let eth_contract = self.currency_contract();

            // Get the fee and the fee receiver from the fee contract.
            let (ethFee, strkFee, fee_receiver) = fee_contract.get_fee_and_owner(collection_addr);
            if(self.isCurrencyEth.read()){
                eth_contract.transferFrom(caller, fee_receiver, ethFee * amount.into());
            }else{
                eth_contract.transferFrom(caller, fee_receiver, strkFee * amount.into());
            }
            // Make user transfer the fee to the fee receiver.

            // Make user transfer the mint price to the collection's contract.
            eth_contract
                .transferFrom(
                    caller, collection_addr, round.price * amount.into()
                ); // todo: uncomment this line for mainnet

            // Mint tokens.
            self._mint_many(caller, amount.into());

            // Update the minted supply for the selected round.
            let currentMinted = self._total_minted.read();
            round.minted_supply += amount.into();
            self._total_minted.write(currentMinted + amount.into());
            self._rounds.write(round_id, round);

            self._users_minted_count.write((caller, round_id), minted_count + amount);
        }

        fn collect_revenue(ref self: ContractState) {
            self.assert_only_owner();

            let status = self._get_status();
            assert(status == Status::Finished, 'Rounds are not finished');
            let eth_contract = self.currency_contract();
            let contract_addr = get_contract_address();
            let balance = eth_contract.balanceOf(contract_addr);
            assert(!balance.is_zero(), 'funds already withdrawed');
            eth_contract.transfer(self._owner.read(), balance);
        }

        fn refund(ref self: ContractState) {
            self._start();

            // Get the address of the caller.
            let caller = get_caller_address();

            let status = self._get_status();
            assert(status == Status::Refundable, 'Refunding is not possible');

            let mut total_spent: u256 = 0;

            let mut i: u8 = 0;

            loop {
                let round = self._rounds.read(i);
                if round.is_zero() {
                    break;
                }

                let mint_count = self._users_minted_count.read((caller, i));
                self._users_minted_count.write((caller, i), 0);
                total_spent += mint_count.into() * round.price;

                i += 1;
            };

            let userTokens : Array<u256> = self.get_tokens_of_user(caller);
            let mut start :u32 = 0;
            loop {
                if start == userTokens.len() {
                    break;
                }
                let tokenId = userTokens.at(start).clone();
                self.burn(tokenId);

                start += 1;
            };
            self._user_total_minted_count.write(caller, 0);

            assert(total_spent > 0, 'No amount to be refunded');

            let eth_contract = self.currency_contract();

            eth_contract.transfer(caller, total_spent);

            self._end();
        }
    }

    //
    // Internal
    //

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn initializer(ref self: ContractState, name_: felt252, symbol_: felt252) {
            self._name.write(name_);
            self._symbol.write(symbol_);

            let mut unsafe_state = src5::SRC5::unsafe_new_contract_state();
            src5::SRC5::InternalImpl::register_interface(ref unsafe_state, interface::IERC721_ID);
            src5::SRC5::InternalImpl::register_interface(ref unsafe_state, 0x5b5e139f);
            src5::SRC5::InternalImpl::register_interface(
                ref unsafe_state, interface::IERC721_METADATA_ID
            );
        }

        fn currency_contract(self: @ContractState) -> IERC20CamelDispatcher {
            let isCurrencyEth = self.isCurrencyEth.read();
            if(isCurrencyEth){
              return IERC20CamelDispatcher {
                contract_address: contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>()
            };
            } else{
             return IERC20CamelDispatcher {
                contract_address: contract_address_const::<0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d>(),
            };
            }
            
        }

        fn get_tokens_of_user(self: @ContractState, userAddr: ContractAddress) -> Array<u256> {
            let mut i : u256 = 0;
            let userMintCount : u256 = self._user_total_minted_count.read(userAddr);
            let mut tokens = ArrayTrait::<u256>::new();

            loop {
                let tokenId = self._users_minted_tokens.read((userAddr, i));

                if i == userMintCount {
                    break;
                }
                tokens.append(tokenId);
                i += 1;
            };

            tokens
        }

        fn _owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            let owner = self._owners.read(token_id);
            match owner.is_zero() {
                bool::False(()) => owner,
                bool::True(()) => panic_with_felt252(Errors::INVALID_TOKEN_ID)
            }
        }

        fn _exists(self: @ContractState, token_id: u256) -> bool {
            !self._owners.read(token_id).is_zero()
        }

        fn _is_approved_or_owner(
            self: @ContractState, spender: ContractAddress, token_id: u256
        ) -> bool {
            let owner = self._owner_of(token_id);
            let is_approved_for_all = ERC721Impl::isApprovedForAll(self, owner, spender);
            owner == spender
                || is_approved_for_all
                || spender == ERC721Impl::getApproved(self, token_id)
        }

        fn _approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            let owner = self._owner_of(token_id);
            assert(owner != to, Errors::APPROVAL_TO_OWNER);

            self._token_approvals.write(token_id, to);
            self.emit(Approval { owner, approved: to, token_id });
        }

        fn _set_approval_for_all(
            ref self: ContractState,
            owner: ContractAddress,
            operator: ContractAddress,
            approved: bool,
        ) {
            assert(owner != operator, Errors::SELF_APPROVAL);
            self._operator_approvals.write((owner, operator), approved);
            self.emit(ApprovalForAll { owner, operator, approved });
        }

        fn _mint(ref self: ContractState, to: ContractAddress, token_id: u256) {
            assert(!to.is_zero(), Errors::INVALID_RECEIVER);
            assert(!self._exists(token_id), Errors::ALREADY_MINTED);

            self._balances.write(to, self._balances.read(to) + 1);
            self._owners.write(token_id, to);
            self._total_supply.write(self._total_supply.read() + 1);

            self.emit(Transfer { from: Zeroable::zero(), to, token_id: token_id });
        }

        fn _transfer(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256
        ) {
            assert(!to.is_zero(), Errors::INVALID_RECEIVER);
            let owner = self._owner_of(token_id);
            assert(from == owner, Errors::WRONG_SENDER);

            // Implicit clear approvals, no need to emit an event
            self._token_approvals.write(token_id, Zeroable::zero());

            self._balances.write(from, self._balances.read(from) - 1);
            self._balances.write(to, self._balances.read(to) + 1);
            self._owners.write(token_id, to);

            self.emit(Transfer { from, to, token_id });
        }

        fn _burn(ref self: ContractState, token_id: u256) {
            let owner = self._owner_of(token_id);

            // Implicit clear approvals, no need to emit an event
            self._token_approvals.write(token_id, Zeroable::zero());

            self._balances.write(owner, self._balances.read(owner) - 1);
            self._owners.write(token_id, Zeroable::zero());
            self._total_supply.write(self._total_supply.read() - 1);

            self.emit(Transfer { from: owner, to: Zeroable::zero(), token_id });
        }

        fn _safe_mint(
            ref self: ContractState, to: ContractAddress, token_id: u256, data: Span<felt252>
        ) {
            self._mint(to, token_id);
            assert(
                _check_on_erc721_received(Zeroable::zero(), to, token_id, data),
                Errors::SAFE_MINT_FAILED
            );
        }

        fn _safe_transfer(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256,
            data: Span<felt252>,
        ) {
            self._transfer(from, to, token_id);
            assert(
                _check_on_erc721_received(from, to, token_id, data), Errors::SAFE_TRANSFER_FAILED
            );
        }

        fn assert_only_owner(self: @ContractState) {
            let owner: ContractAddress = self._owner.read();
            let caller: ContractAddress = get_caller_address();
            assert(!caller.is_zero(), 'Caller is the zero address');
            assert(caller == owner, 'Caller is not the owner');
        }

        fn _transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let previous_owner: ContractAddress = self._owner.read();
            self._owner.write(new_owner);
            self
                .emit(
                    OwnershipTransferred { previous_owner: previous_owner, new_owner: new_owner }
                );
        }

        fn _token_uri(self: @ContractState, token_id: u256) -> Array::<felt252> {

            let tokenFile: felt252 = token_id.try_into().unwrap();
            
            let mut link = ArrayTrait::<felt252>::new();

            let mut j: u8 = 0;

            loop {
                let base_uri_part = self._base_uri_parts.read(j);

                if base_uri_part.is_zero() {
                    break;
                }

                link.append(base_uri_part);

                j += 1;
            };

            if(tokenFile == 0){
                link.append(0x30); 
                link.append(self._base_uri_suffix.read());
                return link;
            }

            let mut revNumber: u256 = 0;
            let mut currentInt: u256 = token_id * 10 + 1;
            loop {
                revNumber = revNumber*10 + currentInt % 10;
                currentInt = currentInt / 10_u256;
                if currentInt < 1 {
                    break;
                };
            };
            loop {
                let lastChar: u256 = revNumber % 10_u256;
                link.append(self._intToChar(lastChar)); 
                revNumber = revNumber / 10_u256;
                if revNumber < 2 {  
                    break;
                };
            };
            link.append(self._base_uri_suffix.read());
            link
        }

        fn _get_status(self: @ContractState) -> Status {
            let timestamp = get_block_timestamp();
            let isCancelled = self._isCancelled.read();
            if isCancelled {
                return Status::Refundable;
            }
            let start_time = self._rounds.read(0).start_time;

            let mut end_time = 0;

            let mut i: u8 = 0;
            loop {
                let round = self._rounds.read(i);
                if round.is_zero() {
                    break;
                };
                end_time = round.end_time;
                i += 1;
            };

            assert(start_time.is_non_zero(), 'Start time is zero');
            assert(end_time.is_non_zero(), 'End time is zero');

            let max_supply = self._max_supply.read();

            if self._total_minted.read() >= max_supply {
                return Status::Finished;
            }

            if timestamp > end_time {
                let max_supply = self._max_supply.read();

                if self._total_minted.read() > max_supply * 35 / 100 {
                    return Status::Finished;
                } else {
                    return Status::Refundable;
                }
            }

            if timestamp > start_time && self._is_initialized.read() {
                return Status::Ongoing;
            }

            Status::Upcoming
        }

        fn _mint_many(ref self: ContractState, to: ContractAddress, count: u256) {
            let mut i = 0;
            let _userTotalMintedCount = self._user_total_minted_count.read(to);
            loop {
                if i == count {
                    break;
                }

                let token_id = self._total_minted.read() + i;

                self._mint(to, token_id);
                self._users_minted_tokens.write((to, _userTotalMintedCount + i), token_id);
                i += 1;
            };
            self._user_total_minted_count.write(to, _userTotalMintedCount + count);
        }

        fn _set_base_uri_parts(ref self: ContractState, new_base_uri_parts: Array<felt252>) {
            assert(new_base_uri_parts.len() != 0, 'Base URI cannot be empty');
            assert(new_base_uri_parts.len() < 256, 'Max length is 256x32 bytes');

            // Remove old base URI parts.
            let mut j: u8 = 0;

            loop {
                if self._base_uri_parts.read(j).is_zero() {
                    break;
                }
                self._base_uri_parts.write(j, Zeroable::zero());
                j += 1;
            };

            // Set new base URI parts.
            let mut i: u8 = 0;

            loop {
                if i.into() == new_base_uri_parts.len() {
                    break;
                }

                let _uri_part = new_base_uri_parts.at(i.into());
                self._base_uri_parts.write(i, _uri_part.clone());

                i += 1;
            }
        }


        fn _start(ref self: ContractState) {
            assert(!self._reentrancy_guard_entered.read(), Errors::REENTRANT_CALL);
            self._reentrancy_guard_entered.write(true);
        }

        fn _end(ref self: ContractState) {
            self._reentrancy_guard_entered.write(false);
        }
    }


    #[external(v0)]
    impl OwnableImpl of ownable::interface::IOwnable<ContractState> {
        fn owner(self: @ContractState) -> ContractAddress {
            self._owner.read()
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            assert(!new_owner.is_zero(), 'New owner is the zero address');
            self.assert_only_owner();
            self._transfer_ownership(new_owner);
        }

        fn renounce_ownership(ref self: ContractState) {
            self.assert_only_owner();
            self._transfer_ownership(Zeroable::zero());
        }
    }

     #[generate_trait]
    impl BaseHelperImpl of BaseHelperTrait {
        
        fn _intToChar(self: @ContractState, input: u256) ->felt252{
            if input == 0 {
                return 0x30;
            }
            else if input == 1{
                return 0x31;
            }
            else if input == 2{
                return 0x32;
            }
            else if input == 3{
                return 0x33;
            }
            else if input == 4{
                return 0x34;
            }
            else if input == 5{
                return 0x35;
            }
            else if input == 6{
                return 0x36;
            }
            else if input == 7{
                return 0x37;
            }
            else if input == 8{
                return 0x38;
            }
            else if input == 9{
                return 0x39;
            }
            0x0
        }
    }

    fn _check_on_erc721_received(
        from: ContractAddress, to: ContractAddress, token_id: u256, data: Span<felt252>
    ) -> bool {
        if (DualCaseSRC5 { contract_address: to }
            .supports_interface(interface::IERC721_RECEIVER_ID)) {
            DualCaseERC721Receiver { contract_address: to }
                .on_erc721_received(
                    get_caller_address(), from, token_id, data
                ) == interface::IERC721_RECEIVER_ID
        } else {
            DualCaseSRC5 { contract_address: to }.supports_interface(account::interface::ISRC6_ID)
        }
    }
}
